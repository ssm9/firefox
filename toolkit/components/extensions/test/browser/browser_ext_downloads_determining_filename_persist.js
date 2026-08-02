"use strict";

// Downloads started by internalSave() ("Save Image As" on an already-loaded
// image, "Save Page As") are written by nsIWebBrowserPersist to a target
// chosen before the Download object exists, so onDeterminingFilename has to
// run before that target reaches the persist object. Reassigning
// download.target.path from Download.start() is too late on this path: the
// bytes are already going somewhere else.
//
// Note this is a different route from "Save Link As", which fetches the link
// through nsExternalHelperAppService and is handled in HelperAppDlg instead.

const URL_PATH = "browser/toolkit/components/extensions/test/browser/data";
const TEST_URL = `https://example.com/${URL_PATH}/test_downloads_referrer.html`;
const DOWNLOAD_URL = `https://example.com/${URL_PATH}/test-download.txt`;
const DOWNLOAD_FILE = "test-download.txt";
const DOWNLOAD_CONTENT = "test download content\n";

let tempDir;

add_setup(() => {
  tempDir = Services.dirsvc.get("TmpD", Ci.nsIFile);
  tempDir.append("test-determining-filename-dir");
  if (!tempDir.exists()) {
    tempDir.create(Ci.nsIFile.DIRECTORY_TYPE, 0o755);
  }

  registerCleanupFunction(function () {
    if (tempDir.exists()) {
      tempDir.remove(true);
    }
  });
});

add_task(async function test_determining_filename_applies_on_persist_path() {
  const extension = ExtensionTestUtils.loadExtension({
    manifest: {
      permissions: ["downloads"],
    },
    async background() {
      browser.downloads.onDeterminingFilename.addListener(item => {
        browser.test.sendMessage("determining", item.filename);
        return { filename: "images/" + item.filename };
      });
      browser.downloads.onChanged.addListener(downloadInfo => {
        if (downloadInfo.state?.current !== "complete") {
          return;
        }
        browser.test.sendMessage("download-completed");
      });

      // Ensures the parent-side listener registration has completed.
      await browser.runtime.getBrowserInfo();

      browser.test.sendMessage("bg-page:ready");
    },
  });

  await extension.startup();
  await extension.awaitMessage("bg-page:ready");

  const chosenFile = tempDir.clone();
  chosenFile.append(DOWNLOAD_FILE);

  await BrowserTestUtils.withNewTab({ gBrowser, url: TEST_URL }, async () => {
    internalSave(
      DOWNLOAD_URL,
      null, // aOriginalURL
      null, // aDocument
      DOWNLOAD_FILE, // aDefaultFileName
      null, // aContentDisposition
      "text/plain", // aContentType
      true, // aShouldBypassCache
      null, // aFilePickerTitleKey
      { file: chosenFile, uri: Services.io.newURI(DOWNLOAD_URL) },
      null, // aReferrerInfo
      null, // aCookieJarSettings
      null, // aInitiatingDocument
      true, // aSkipPrompt
      null, // aCacheKey
      false, // aIsContentWindowPrivate
      gBrowser.contentPrincipal
    );

    const receivedFilename = await extension.awaitMessage("determining");
    is(
      receivedFilename,
      DOWNLOAD_FILE,
      "onDeterminingFilename received the leaf name, not the full target path"
    );
  });

  await extension.awaitMessage("download-completed");

  const organized = PathUtils.join(tempDir.path, "images", DOWNLOAD_FILE);

  ok(await IOUtils.exists(organized), `File was saved to ${organized}`);
  // Checking the contents matters: when the suggestion is applied too late the
  // persist object still writes to the original path and the download core
  // leaves behind an empty placeholder at the suggested one.
  is(
    await IOUtils.readUTF8(organized),
    DOWNLOAD_CONTENT,
    "Suggested path holds the downloaded bytes, not an empty placeholder"
  );
  ok(
    !(await IOUtils.exists(chosenFile.path)),
    "File was not left behind at the original target path"
  );

  await extension.unload();
});

// When "always ask where to save" is on, the picker reopens in the last-used
// directory. Once a suggestion has organised a download into a subfolder that
// becomes the last-used directory, so resolving the next suggestion against it
// nests them (images/documents/, then images/documents/documents/...). The
// hook has to run before the picker and against the download directory.
add_task(async function test_suggestion_does_not_nest_in_last_used_dir() {
  const driftedDir = PathUtils.join(tempDir.path, "images");
  await IOUtils.makeDirectory(driftedDir, { ignoreExisting: true });

  await SpecialPowers.pushPrefEnv({
    set: [
      ["browser.download.useDownloadDir", false],
      ["browser.download.folderList", 2],
      ["browser.download.dir", tempDir.path],
      ["browser.download.lastDir", driftedDir],
    ],
  });

  let seenDisplayDirectory = null;
  let seenDefaultString = null;

  const MockFilePicker = SpecialPowers.MockFilePicker;
  MockFilePicker.init();
  MockFilePicker.showCallback = function (fp) {
    seenDisplayDirectory = fp.displayDirectory.path;
    seenDefaultString = fp.defaultString;
    const destFile = new FileUtils.File(fp.displayDirectory.path);
    destFile.append(fp.defaultString);
    MockFilePicker.setFiles([destFile]);
    MockFilePicker.returnValue = MockFilePicker.returnOK;
  };

  const extension = ExtensionTestUtils.loadExtension({
    manifest: {
      permissions: ["downloads"],
    },
    async background() {
      browser.downloads.onDeterminingFilename.addListener(item => {
        return { filename: "documents/" + item.filename };
      });
      browser.downloads.onChanged.addListener(downloadInfo => {
        if (downloadInfo.state?.current !== "complete") {
          return;
        }
        browser.test.sendMessage("download-completed");
      });

      await browser.runtime.getBrowserInfo();

      browser.test.sendMessage("bg-page:ready");
    },
  });

  await extension.startup();
  await extension.awaitMessage("bg-page:ready");

  await BrowserTestUtils.withNewTab({ gBrowser, url: TEST_URL }, async () => {
    internalSave(
      DOWNLOAD_URL,
      null, // aOriginalURL
      null, // aDocument
      DOWNLOAD_FILE, // aDefaultFileName
      null, // aContentDisposition
      "text/plain", // aContentType
      true, // aShouldBypassCache
      null, // aFilePickerTitleKey
      null, // aChosenData: go through promiseTargetFile
      null, // aReferrerInfo
      null, // aCookieJarSettings
      null, // aInitiatingDocument
      false, // aSkipPrompt
      null, // aCacheKey
      false, // aIsContentWindowPrivate
      gBrowser.contentPrincipal
    );

    await extension.awaitMessage("download-completed");
  });

  is(
    seenDisplayDirectory,
    PathUtils.join(tempDir.path, "documents"),
    "Picker opened at the suggested directory, not the last-used one"
  );
  is(
    seenDefaultString,
    DOWNLOAD_FILE,
    "Picker offered the suggested leaf name"
  );

  const organized = PathUtils.join(tempDir.path, "documents", DOWNLOAD_FILE);
  const nested = PathUtils.join(driftedDir, "documents", DOWNLOAD_FILE);

  is(
    await IOUtils.readUTF8(organized),
    DOWNLOAD_CONTENT,
    `File was saved to ${organized}`
  );
  ok(!(await IOUtils.exists(nested)), "Suggestion did not nest under images/");

  MockFilePicker.cleanup();
  await SpecialPowers.popPrefEnv();
  await extension.unload();
});

// The suggestion only supplies the dialog's starting point. Navigating away
// from it is an explicit choice and has to win: nothing may re-apply the
// suggestion to the directory the user actually picked.
add_task(async function test_explicitly_chosen_directory_wins() {
  // Own download directory: a name collision with an earlier task would make
  // the suggestion uniquify, changing the leaf the picker offers.
  const downloadDir = PathUtils.join(tempDir.path, "explicit-nav");
  const chosenDir = PathUtils.join(downloadDir, "manual");
  await IOUtils.makeDirectory(chosenDir, { createAncestors: true });

  await SpecialPowers.pushPrefEnv({
    set: [
      ["browser.download.useDownloadDir", false],
      ["browser.download.folderList", 2],
      ["browser.download.dir", downloadDir],
    ],
  });

  const MockFilePicker = SpecialPowers.MockFilePicker;
  MockFilePicker.init();
  MockFilePicker.showCallback = function (fp) {
    // Ignore fp.displayDirectory: this is the user navigating elsewhere.
    const destFile = new FileUtils.File(chosenDir);
    destFile.append(fp.defaultString);
    MockFilePicker.setFiles([destFile]);
    MockFilePicker.returnValue = MockFilePicker.returnOK;
  };

  const extension = ExtensionTestUtils.loadExtension({
    manifest: {
      permissions: ["downloads"],
    },
    async background() {
      browser.downloads.onDeterminingFilename.addListener(item => {
        return { filename: "documents/" + item.filename };
      });
      browser.downloads.onChanged.addListener(downloadInfo => {
        if (downloadInfo.state?.current !== "complete") {
          return;
        }
        browser.test.sendMessage("download-completed");
      });

      await browser.runtime.getBrowserInfo();

      browser.test.sendMessage("bg-page:ready");
    },
  });

  await extension.startup();
  await extension.awaitMessage("bg-page:ready");

  await BrowserTestUtils.withNewTab({ gBrowser, url: TEST_URL }, async () => {
    internalSave(
      DOWNLOAD_URL,
      null, // aOriginalURL
      null, // aDocument
      DOWNLOAD_FILE, // aDefaultFileName
      null, // aContentDisposition
      "text/plain", // aContentType
      true, // aShouldBypassCache
      null, // aFilePickerTitleKey
      null, // aChosenData: go through promiseTargetFile
      null, // aReferrerInfo
      null, // aCookieJarSettings
      null, // aInitiatingDocument
      false, // aSkipPrompt
      null, // aCacheKey
      false, // aIsContentWindowPrivate
      gBrowser.contentPrincipal
    );

    await extension.awaitMessage("download-completed");
  });

  is(
    await IOUtils.readUTF8(PathUtils.join(chosenDir, DOWNLOAD_FILE)),
    DOWNLOAD_CONTENT,
    "File was saved to the directory the user navigated to"
  );
  ok(
    !(await IOUtils.exists(
      PathUtils.join(chosenDir, "documents", DOWNLOAD_FILE)
    )),
    "Suggestion was not re-applied inside the chosen directory"
  );
  ok(
    !(await IOUtils.exists(
      PathUtils.join(downloadDir, "documents", DOWNLOAD_FILE)
    )),
    "File was not diverted back to the suggested directory"
  );

  MockFilePicker.cleanup();
  await SpecialPowers.popPrefEnv();
  await extension.unload();
});
