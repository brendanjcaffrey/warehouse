// sends a message to the background page so it can know what tab this is running in
chrome.runtime.sendMessage({type: "init"}, function(response) {});

// respond to a message from the background page
chrome.runtime.onMessage.addListener(
  function(request, sender, sendResponse) {
    var command = request.type;
    if (command != "play-pause" && command != "next" && command != "prev") return;

    // inject javascript to send a message to the web page
    var script = document.createElement("script");
    script.textContent = 'window.postMessage({source: "itunes-streamer", type: "' + command + '"}, "*");';
    (document.head||document.documentElement).appendChild(script);
    script.parentNode.removeChild(script);
  }
);
