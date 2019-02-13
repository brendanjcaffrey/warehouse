var tab;
chrome.runtime.onMessage.addListener(function(request, sender, sendResponse) {
  // when we get an init message, we just store the tab so we can send messages to it later
  if (request.type == "init") { tab = sender.tab; }
});

// this comes from a keyboard shortcut - just pass it along to the content script
// since the background page can't inject javascript itself
chrome.commands.onCommand.addListener(function(command) {
  chrome.tabs.sendMessage(tab.id, { type: command });
});
