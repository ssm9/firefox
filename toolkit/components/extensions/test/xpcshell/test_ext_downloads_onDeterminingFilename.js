"use strict";

const { Downloads } = ChromeUtils.importESModule(
  "resource://gre/modules/Downloads.sys.mjs"
);

const gServer = createHttpServer();
gServer.registerDirectory("/data/", do_get_file("data"));

const WINDOWS = AppConstants.platform == "win";

const BASE = `http://localhost:${gServer.identity.primaryPort}/`;
const FILE_NAME = "file_download.txt";
const FILE_URL = BASE + "data/" + FILE_NAME;

let downloadDir;

function setup() {
  downloadDir = FileUtils.getDir("TmpD", ["downloads"]);
  downloadDir.createUnique(
    Ci.nsIFile.DIRECTORY_TYPE,
    FileUtils.PERMS_DIRECTORY
  );
  info(`Using download directory ${downloadDir.path}`);

  Services.prefs.setIntPref("browser.download.folderList", 2);
  Services.prefs.setComplexValue(
    "browser.download.dir",
    Ci.nsIFile,
    downloadDir
  );
  // Avoid showing the file picker.
  Services.prefs.setBoolPref("browser.download.useDownloadDir", true);

  registerCleanupFunction(() => {
    Services.prefs.clearUserPref("browser.download.folderList");
    Services.prefs.clearUserPref("browser.download.dir");
    Services.prefs.clearUserPref("browser.download.useDownloadDir");

    let entries = downloadDir.directoryEntries;
    while (entries.hasMoreElements()) {
      let entry = entries.nextFile;
      entry.remove(false);
    }
    downloadDir.remove(false);
  });
}

async function waitForDownloads() {
  let list = await Downloads.getList(Downloads.ALL);
  let downloads = await list.getAll();
  let inprogress = downloads.filter(dl => !dl.stopped);
  await Promise.all(inprogress.map(dl => dl.whenSucceeded()));
}

function exists(filename) {
  let file = downloadDir.clone();
  for (let component of filename.split("/")) {
    file.append(component);
  }
  return file.exists();
}

function remove(filename, recursive = false) {
  let file = downloadDir.clone();
  for (let component of filename.split("/")) {
    file.append(component);
  }
  if (file.exists()) {
    file.remove(recursive);
  }
}

function backgroundScript() {
  browser.test.onMessage.addListener(async (msg, ...args) => {
    if (msg == "setup-listener") {
      let suggestion = args[0];
      browser.downloads.onDeterminingFilename.addListener((item, suggest) => {
        browser.test.assertTrue(
          !!item && typeof item.id == "number",
          "listener receives a DownloadItem with an id"
        );
        browser.test.assertTrue(
          typeof item.url == "string",
          "DownloadItem has a url"
        );
        // Echo the item back so the test can inspect it.
        browser.test.sendMessage("determining", item);
        if (suggestion === null) {
          suggest();
        } else {
          suggest(suggestion);
        }
      });
      browser.test.sendMessage("listener-ready");
    } else if (msg == "download.request") {
      try {
        let id = await browser.downloads.download(args[0]);
        browser.test.sendMessage("download.done", { status: "success", id });
      } catch (error) {
        browser.test.sendMessage("download.done", {
          status: "error",
          errmsg: error.message,
        });
      }
    }
  });

  browser.test.sendMessage("ready");
}

function loadExtension() {
  return ExtensionTestUtils.loadExtension({
    background: `(${backgroundScript})()`,
    manifest: {
      permissions: ["downloads"],
    },
  });
}

add_task(async function test_onDeterminingFilename_override() {
  setup();

  let extension = loadExtension();
  await extension.startup();
  await extension.awaitMessage("ready");

  extension.sendMessage("setup-listener", { filename: "renamed.txt" });
  await extension.awaitMessage("listener-ready");

  extension.sendMessage("download.request", { url: FILE_URL });
  let item = await extension.awaitMessage("determining");
  equal(item.url, FILE_URL, "listener saw the right url");

  let result = await extension.awaitMessage("download.done");
  equal(result.status, "success", "download succeeded");

  await waitForDownloads();

  ok(exists("renamed.txt"), "file saved under the suggested filename");
  ok(!exists(FILE_NAME), "file was not saved under the original filename");

  remove("renamed.txt");
  await extension.unload();
});

add_task(async function test_onDeterminingFilename_subdirectory() {
  let extension = loadExtension();
  await extension.startup();
  await extension.awaitMessage("ready");

  extension.sendMessage("setup-listener", { filename: "sub/dir/renamed.txt" });
  await extension.awaitMessage("listener-ready");

  extension.sendMessage("download.request", { url: FILE_URL });
  await extension.awaitMessage("determining");
  let result = await extension.awaitMessage("download.done");
  equal(result.status, "success", "download succeeded");

  await waitForDownloads();

  ok(exists("sub/dir/renamed.txt"), "file saved under suggested subdirectory");

  remove("sub", true);
  await extension.unload();
});

add_task(async function test_onDeterminingFilename_no_suggestion() {
  let extension = loadExtension();
  await extension.startup();
  await extension.awaitMessage("ready");

  // suggest() called with no arguments -> keep the original filename.
  extension.sendMessage("setup-listener", null);
  await extension.awaitMessage("listener-ready");

  extension.sendMessage("download.request", { url: FILE_URL });
  await extension.awaitMessage("determining");
  let result = await extension.awaitMessage("download.done");
  equal(result.status, "success", "download succeeded");

  await waitForDownloads();

  ok(exists(FILE_NAME), "file saved under the original filename");

  remove(FILE_NAME);
  await extension.unload();
});

add_task(async function test_onDeterminingFilename_invalid_ignored() {
  let extension = loadExtension();
  await extension.startup();
  await extension.awaitMessage("ready");

  // An absolute path is invalid and must be ignored, keeping the default.
  let absolute = WINDOWS ? "C:\\evil.txt" : "/etc/evil.txt";
  extension.sendMessage("setup-listener", { filename: absolute });
  await extension.awaitMessage("listener-ready");

  extension.sendMessage("download.request", { url: FILE_URL });
  await extension.awaitMessage("determining");
  let result = await extension.awaitMessage("download.done");
  equal(result.status, "success", "download succeeded");

  await waitForDownloads();

  ok(exists(FILE_NAME), "invalid suggestion ignored, default filename used");

  remove(FILE_NAME);
  await extension.unload();
});

add_task(async function test_onDeterminingFilename_parent_ref_ignored() {
  let extension = loadExtension();
  await extension.startup();
  await extension.awaitMessage("ready");

  extension.sendMessage("setup-listener", { filename: "../escape.txt" });
  await extension.awaitMessage("listener-ready");

  extension.sendMessage("download.request", { url: FILE_URL });
  await extension.awaitMessage("determining");
  let result = await extension.awaitMessage("download.done");
  equal(result.status, "success", "download succeeded");

  await waitForDownloads();

  ok(exists(FILE_NAME), "back-reference suggestion ignored");

  remove(FILE_NAME);
  await extension.unload();
});
