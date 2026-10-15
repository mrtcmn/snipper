// Popup: connection status and quick actions.
const statusEl = document.getElementById("status");
const dot = document.getElementById("dot");
const messageEl = document.getElementById("message");
const portInput = document.getElementById("port");

function send(message) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage(message, (response) => {
      resolve(chrome.runtime.lastError ? { ok: false, error: chrome.runtime.lastError.message } : response || { ok: false });
    });
  });
}

function show(text, kind = "") {
  messageEl.hidden = !text;
  messageEl.textContent = text || "";
  messageEl.className = `message ${kind}`;
}

async function refresh() {
  const status = await send({ type: "status" });
  if (status.ok) {
    dot.className = "dot on";
    const count = Number(status.snips || 0).toLocaleString();
    statusEl.textContent = `Connected · ${count} snips · ${status.semantic ? status.search : "keyword search"}`;
  } else {
    dot.className = "dot off";
    statusEl.textContent = status.offline ? "Stash isn't running" : status.error || "Not connected";
    show("Open the Stash app on your Mac. Saves made now are queued and sent when it starts.", "");
  }
}

document.querySelectorAll("[data-action]").forEach((button) => {
  button.addEventListener("click", async () => {
    const action = button.dataset.action;
    button.disabled = true;
    show("");
    const result = await send({ type: action });
    button.disabled = false;
    if (action === "import-bookmarks") {
      window.close();
      return;
    }
    if (result.ok) {
      show(result.updated || result.unchanged ? "Already in Stash — updated." : "Saved to Stash.", "ok");
      setTimeout(() => window.close(), 700);
    } else if (result.queued) {
      show("Stash isn't running — saved for later.", "");
    } else {
      show(result.error || "Something went wrong.", "error");
    }
  });
});

document.getElementById("open").addEventListener("click", async () => {
  await send({ type: "open" });
  window.close();
});

chrome.storage.local.get({ port: 47615 }).then(({ port }) => {
  portInput.value = port;
});
portInput.addEventListener("change", async () => {
  const port = Number(portInput.value);
  if (port >= 1024 && port <= 65535) {
    await chrome.storage.local.set({ port });
    refresh();
  }
});

refresh();
