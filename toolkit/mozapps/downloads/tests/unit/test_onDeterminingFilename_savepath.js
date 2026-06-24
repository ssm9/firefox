/* Any copyright is dedicated to the Public Domain.
 * http://creativecommons.org/publicdomain/zero/1.0/ */

// Verifies that the no-prompt save-to-disk path in HelperAppDlg consults the
// filename determiners registered with DownloadIntegration (the mechanism
// behind downloads.onDeterminingFilename), so that downloads that are not
// initiated by an extension also go through filename determination.

const { DownloadIntegration } = ChromeUtils.importESModule(
  "resource://gre/modules/DownloadIntegration.sys.mjs"
);
const { nsUnknownContentTypeDialog } = ChromeUtils.importESModule(
  "resource://gre/modules/HelperAppDlg.sys.mjs"
);
const { FileUtils } = ChromeUtils.importESModule(
  "resource://gre/modules/FileUtils.sys.mjs"
);

let downloadDir;

function setup() {
  // DownloadLastDir / ContentPrefService2 (used by the file picker path) need
  // a profile directory.
  do_get_profile();

  downloadDir = FileUtils.getDir("TmpD", ["odf-savepath"]);
  downloadDir.createUnique(
    Ci.nsIFile.DIRECTORY_TYPE,
    FileUtils.PERMS_DIRECTORY
  );

  Services.prefs.setIntPref("browser.download.folderList", 2);
  Services.prefs.setComplexValue(
    "browser.download.dir",
    Ci.nsIFile,
    downloadDir
  );
  Services.prefs.setBoolPref("browser.download.useDownloadDir", true);

  registerCleanupFunction(() => {
    Services.prefs.clearUserPref("browser.download.folderList");
    Services.prefs.clearUserPref("browser.download.dir");
    Services.prefs.clearUserPref("browser.download.useDownloadDir");
    if (downloadDir.exists()) {
      downloadDir.remove(true);
    }
  });
}

// A minimal nsIHelperAppLauncher stand-in exposing the properties read by
// promptForSaveToFileAsync and its determiner consult.
function makeLauncher(suggestedFileName) {
  return {
    QueryInterface: ChromeUtils.generateQI(["nsIHelperAppLauncher"]),
    source: Services.io.newURI("https://example.com/" + suggestedFileName),
    suggestedFileName,
    MIMEInfo: {
      MIMEType: "application/octet-stream",
      primaryExtension: "bin",
      getFileExtensions: () => ({ hasMore: () => false }),
    },
    saveDestinationAvailable() {},
  };
}

function promptForSave(launcher, defaultFileName) {
  return new Promise(resolve => {
    launcher.saveDestinationAvailable = file => resolve(file);
    let dialog = new nsUnknownContentTypeDialog();
    // No context: the auto-save (useDownloadDir) branch resolves without a
    // window, returning before any file picker is shown.
    dialog.promptForSaveToFileAsync(
      launcher,
      null,
      defaultFileName,
      ".bin",
      false
    );
  });
}

add_task(async function test_determiner_overrides_savepath() {
  setup();

  let sawDownload = null;
  let determiner = async ({ download, targetPath }) => {
    sawDownload = download;
    Assert.equal(targetPath, "original.bin", "determiner sees proposed name");
    return { filename: "overridden.bin" };
  };
  DownloadIntegration.addFilenameDeterminer(determiner);
  registerCleanupFunction(() =>
    DownloadIntegration.removeFilenameDeterminer(determiner)
  );

  let file = await promptForSave(makeLauncher("original.bin"), "original.bin");

  Assert.ok(sawDownload, "determiner was consulted on the native save path");
  Assert.equal(
    file.leafName,
    "overridden.bin",
    "save path used the determiner's suggested filename"
  );
  Assert.equal(file.parent.path, downloadDir.path, "saved in download dir");

  DownloadIntegration.removeFilenameDeterminer(determiner);
});

add_task(async function test_no_determiner_keeps_default() {
  let file = await promptForSave(makeLauncher("keep.bin"), "keep.bin");
  Assert.equal(
    file.leafName,
    "keep.bin",
    "with no determiner the proposed filename is kept"
  );
});

add_task(async function test_path_suggestion_reduced_to_leaf() {
  // The native save path resolves only a leaf name relative to the download
  // directory, so any directory components in a suggestion are stripped. This
  // neutralizes absolute paths and traversal on this path (subdirectories are
  // not honored here, unlike the extension download() path).
  let determiner = async () => ({ filename: "/absolute/evil.bin" });
  DownloadIntegration.addFilenameDeterminer(determiner);

  let file = await promptForSave(makeLauncher("safe.bin"), "safe.bin");
  Assert.equal(
    file.leafName,
    "evil.bin",
    "directory components stripped, leaf saved in the download dir"
  );
  Assert.equal(
    file.parent.path,
    downloadDir.path,
    "file stays inside the download dir"
  );

  DownloadIntegration.removeFilenameDeterminer(determiner);
});

// A mock nsIFilePicker that records the defaultString it is given (so the test
// can assert the determined name pre-fills the dialog) and resolves with a
// file in the download directory, simulating the user accepting the dialog.
function registerMockFilePicker() {
  let captured = { defaultString: null };
  let mockPicker = {
    QueryInterface: ChromeUtils.generateQI(["nsIFilePicker"]),
    init() {},
    appendFilter() {},
    appendFilters() {},
    set defaultString(value) {
      captured.defaultString = value;
    },
    get defaultString() {
      return captured.defaultString;
    },
    defaultExtension: "",
    displayDirectory: null,
    get file() {
      let f = downloadDir.clone();
      f.append(captured.defaultString || "fallback.bin");
      return f;
    },
    open(callback) {
      // XPConnect wraps the JS function HelperAppDlg passes into an
      // nsIFilePickerShownCallback, so invoke its done() method.
      Services.tm.dispatchToMainThread(() =>
        callback.done(Ci.nsIFilePicker.returnOK)
      );
    },
  };

  let factory = {
    createInstance(iid) {
      return mockPicker.QueryInterface(iid);
    },
    QueryInterface: ChromeUtils.generateQI(["nsIFactory"]),
  };

  let registrar = Components.manager.QueryInterface(Ci.nsIComponentRegistrar);
  let cid = Components.ID("{b1b2c3d4-0000-4000-8000-0badf00dca11}");
  let contractId = "@mozilla.org/filepicker;1";
  registrar.registerFactory(cid, "MockFilePicker", contractId, factory);

  return {
    captured,
    restore() {
      // Unregistering our factory restores the contract ID to the original
      // implementation, whose CID mapping is untouched.
      registrar.unregisterFactory(cid, factory);
    },
  };
}

// A minimal non-private window stand-in. DownloadLastDir reads
// window.docShell as an nsILoadContext (usePrivateBrowsing), and
// _maybeDetermineFilename passes the window to
// PrivateBrowsingUtils.isContentWindowPrivate.
function makeFakeWindow() {
  let loadContext = {
    QueryInterface: ChromeUtils.generateQI(["nsILoadContext"]),
    usePrivateBrowsing: false,
    isContent: true,
  };
  return {
    docShell: {
      QueryInterface: () => loadContext,
    },
  };
}

// A context that hands back the fake parent window for the file picker path.
function makeContextWithWindow() {
  let win = makeFakeWindow();
  return {
    QueryInterface: ChromeUtils.generateQI(["nsIInterfaceRequestor"]),
    getInterface(iid) {
      if (iid.equals(Ci.nsIDOMWindow)) {
        return win;
      }
      throw Components.Exception("", Cr.NS_ERROR_NO_INTERFACE);
    },
  };
}

add_task(async function test_determiner_prefills_save_as_picker() {
  // With useDownloadDir off (or aForcePrompt), the Save As dialog is shown.
  // The determiner's suggestion should pre-fill the picker's defaultString.
  Services.prefs.setBoolPref("browser.download.useDownloadDir", false);

  let determiner = async () => ({ filename: "picked-name.bin" });
  DownloadIntegration.addFilenameDeterminer(determiner);

  let mock = registerMockFilePicker();
  let context = makeContextWithWindow();

  let file = await new Promise(resolve => {
    let launcher = makeLauncher("default.bin");
    launcher.saveDestinationAvailable = f => resolve(f);
    let dialog = new nsUnknownContentTypeDialog();
    dialog.promptForSaveToFileAsync(
      launcher,
      context,
      "default.bin",
      ".bin",
      true
    );
  });

  Assert.equal(
    mock.captured.defaultString,
    "picked-name.bin",
    "determined name pre-filled the Save As dialog"
  );
  Assert.equal(
    file.leafName,
    "picked-name.bin",
    "accepted file uses the determined name"
  );

  DownloadIntegration.removeFilenameDeterminer(determiner);
  mock.restore();
  Services.prefs.setBoolPref("browser.download.useDownloadDir", true);
});
