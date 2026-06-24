/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/. */

"use strict";

this.downloads = class extends ExtensionAPI {
  getAPI(context) {
    return {
      downloads: {
        // onDeterminingFilename passes the listener a `suggest` callback. The
        // callback cannot be sent across the process boundary, so it is
        // synthesized here in the child and the resulting suggestion is sent
        // back to the parent as the listener's response. This mirrors the
        // approach used by webRequest.onAuthRequired's asyncBlocking listeners.
        onDeterminingFilename: new EventManager({
          context,
          name: "downloads.onDeterminingFilename",
          register: fire => {
            const listener = downloadItem => {
              // suggestionResponse is set to `promise` when the listener calls
              // suggest() synchronously, so the suggestion is returned even
              // when the listener does not also return true. This mirrors
              // runtime.onMessage's sendResponse handling.
              let suggestionResponse;
              let suggestCallback;
              const promise = new Promise(resolve => {
                suggestCallback = Cu.exportFunction(suggestion => {
                  suggestionResponse = promise;
                  resolve(suggestion ?? null);
                }, context.cloneScope);
              });

              // The listener either calls suggest() (synchronously or, after
              // returning true, asynchronously) or returns nothing to accept
              // the default filename.
              let result = fire.raw(downloadItem, suggestCallback);
              if (result === true) {
                return promise;
              }
              return suggestionResponse ?? null;
            };

            const parentEvent = context.childManager.getParentEvent(
              "downloads.onDeterminingFilename"
            );
            parentEvent.addListener(listener);
            return () => {
              parentEvent.removeListener(listener);
            };
          },
        }).api(),
      },
    };
  }
};
