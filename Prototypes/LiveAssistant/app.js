const $ = (selector) => document.querySelector(selector);

const scenarios = [
  {
    question: "“Tell me about a time you improved the performance of a critical system.”",
    transcript: "That’s relevant to this team. Tell me about a time you improved the performance of a critical system.",
    partial: "The best example is probably our checkout path...",
    lead: "Lead with the checkout latency story",
    points: [
      ["Set the stakes.", "Checkout p95 had climbed to <mark>1.8 seconds</mark> during peak traffic and was starting to affect conversion."],
      ["Name your move.", "I traced the path across services, found an N+1 inventory lookup, and proposed a request-scoped batcher with a short-lived cache."],
      ["Land the result.", "We brought p95 down by <mark>41%</mark>, held the gain through holiday load, and added a latency budget to stop regressions."]
    ],
    proof: [["41%", "p95 latency reduction"], ["18k", "peak requests / minute"], ["0", "regressions over 6 months"]],
    watchTitle: "They may ask what you personally owned",
    watchBody: "Be precise: you led diagnosis and rollout; the inventory team owned the service-side API change.",
    followup: "“How did you prove the cache would not return stale inventory?”"
  },
  {
    question: "“What did you learn when that launch did not go to plan?”",
    transcript: "Thanks. What did you learn when that launch did not go to plan?",
    partial: "One launch that changed how I work was the first rollout of...",
    lead: "Use the rollout incident—then show the changed habit",
    points: [
      ["Own the miss.", "I optimized for the happy path and underestimated how slowly older clients would drain from the fleet."],
      ["Show your response.", "I paused the rollout, wrote the compatibility shim, and kept support and product updated with a single incident timeline."],
      ["Name the durable lesson.", "Every later migration shipped with a client-age dashboard, explicit rollback criteria, and a rehearsed mixed-version test."]
    ],
    proof: [["27 min", "to halt the rollout"], ["2 days", "to safe relaunch"], ["100%", "later migrations rehearsed"]],
    watchTitle: "Avoid making the story sound too polished",
    watchBody: "Say what you missed before explaining the recovery. The learning is stronger when the mistake is concrete.",
    followup: "“How did you rebuild confidence with the teams affected?”"
  },
  {
    question: "“How do you make a fast prototype reliable enough for other people to depend on?”",
    transcript: "How do you make a fast prototype reliable enough for other people to depend on?",
    partial: "I try to identify the one failure that would destroy trust...",
    lead: "Frame reliability as a product constraint, not cleanup",
    points: [
      ["Start with the trust boundary.", "I ask which failure would make a user stop relying on the product—in this case, losing transcript turns during a reconnect."],
      ["Make recovery observable.", "Events carry sequence IDs; the client resumes from its last received ID and shows whether it replayed or took a snapshot."],
      ["Test the ugly path.", "I inject disconnects, app restarts, and stale clients before adding features whose value depends on a healthy stream."]
    ],
    proof: [["1", "ordered event stream"], ["0", "lost turns on resume"], ["10 s", "maximum retry backoff"]],
    watchTitle: "They may challenge the use of SSE",
    watchBody: "Explain that the traffic is mostly downstream. Commands remain normal idempotent HTTP requests, so a socket adds little value in v1.",
    followup: "“When would you move from SSE to a WebSocket?”"
  }
];

let scenarioIndex = 0;
let reconnecting = false;
let toastTimer;

function showToast(message) {
  const toast = $("#toast");
  toast.textContent = message;
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toast.hidden = true; }, 1800);
}

function renderScenario(index) {
  const scenario = scenarios[index];
  $("#questionText").textContent = scenario.question;
  $("#transcriptQuestion").textContent = scenario.transcript;
  $("#partialWords").textContent = scenario.partial;
  $("#answerLead").textContent = scenario.lead;
  $("#watchTitle").textContent = scenario.watchTitle;
  $("#watchBody").textContent = scenario.watchBody;
  $("#followupText").textContent = scenario.followup;

  $("#talkingPoints").innerHTML = scenario.points.map((point, pointIndex) => `
    <li><span>0${pointIndex + 1}</span><p><strong>${point[0]}</strong> ${point[1]}</p></li>
  `).join("");

  $("#proofList").innerHTML = scenario.proof.map(([value, label]) => `
    <li><strong>${value}</strong><span>${label}</span></li>
  `).join("");

  const card = $("#answerCard");
  card.animate(
    [{ opacity: .45, transform: "translateY(5px)" }, { opacity: 1, transform: "translateY(0)" }],
    { duration: 260, easing: "ease-out" }
  );
}

function nextScenario() {
  scenarioIndex = (scenarioIndex + 1) % scenarios.length;
  renderScenario(scenarioIndex);
  showToast("New guidance generated");
}

function simulateReconnect() {
  if (reconnecting) return;
  reconnecting = true;
  $("#connectionPopover").hidden = true;

  const chip = $("#connectionButton");
  const banner = $("#recoveryBanner");
  chip.classList.remove("is-connected");
  chip.classList.add("is-reconnecting");
  $("#connectionEyebrow").textContent = "RECONNECTING";
  $("#connectionLabel").textContent = "Attempt 1 · 0.5 s";
  $("#resumeWatermark").innerHTML = `
    <span class="banner-spinner" aria-hidden="true"></span>
    <span><strong>Stream interrupted</strong><small>Capture continues on the Mac</small></span>
  `;

  banner.classList.remove("is-recovered");
  $("#recoveryTitle").textContent = "Connection interrupted";
  $("#recoveryDetail").textContent = "The Mac keeps recording. Reconnecting…";
  banner.hidden = false;

  setTimeout(() => {
    $("#connectionLabel").textContent = "Resuming from #2,487";
  }, 850);

  setTimeout(() => {
    chip.classList.remove("is-reconnecting");
    chip.classList.add("is-connected");
    $("#connectionEyebrow").textContent = "CAUGHT UP";
    $("#connectionLabel").textContent = "Connected to Davide’s Mac";
    $("#resumeWatermark").innerHTML = `
      <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M4 10l4 4 8-9"/></svg>
      <span><strong>Everything received</strong><small>Event 2,490 · 3 events replayed</small></span>
    `;
    banner.classList.add("is-recovered");
    $("#recoveryTitle").textContent = "Back online · nothing lost";
    $("#recoveryDetail").textContent = "Resumed at #2,487 and replayed 3 events.";
    reconnecting = false;
    setTimeout(() => { banner.hidden = true; }, 2300);
  }, 2300);
}

$("#connectionButton").addEventListener("click", (event) => {
  event.stopPropagation();
  const popover = $("#connectionPopover");
  popover.hidden = !popover.hidden;
  $("#connectionButton").setAttribute("aria-expanded", String(!popover.hidden));
});

document.addEventListener("click", (event) => {
  if (!event.target.closest("#connectionPopover") && !event.target.closest("#connectionButton")) {
    $("#connectionPopover").hidden = true;
    $("#connectionButton").setAttribute("aria-expanded", "false");
  }
});

$("#simulateDropButton").addEventListener("click", simulateReconnect);
$("#popoverDropButton").addEventListener("click", simulateReconnect);

$("#assistantToggle").addEventListener("change", (event) => {
  const active = event.target.checked;
  $("#assistantState").textContent = active ? "Watching the conversation" : "Transcript only";
  ["#listeningStrip", "#answerCard", ".evidence-grid", ".next-question-card", ".workspace-heading"].forEach((selector) => {
    const element = $(selector);
    if (element) element.hidden = !active;
  });
  $("#pausedState").hidden = active;
});

$("#nextMomentButton").addEventListener("click", nextScenario);
document.addEventListener("keydown", (event) => {
  if (event.key.toLowerCase() === "n" && !event.metaKey && !event.ctrlKey && !event.altKey) nextScenario();
});

$("#pinButton").addEventListener("click", (event) => {
  const button = event.currentTarget;
  button.classList.toggle("is-active");
  showToast(button.classList.contains("is-active") ? "Answer pinned" : "Answer unpinned");
});

$("#copyButton").addEventListener("click", async () => {
  const answer = [
    $("#answerLead").textContent,
    ...Array.from($("#talkingPoints").querySelectorAll("p")).map((item) => item.textContent)
  ].join("\n\n");
  try {
    await navigator.clipboard.writeText(answer);
    showToast("Copied answer");
  } catch {
    showToast("Copy is unavailable in this preview");
  }
});

$("#shorterButton").addEventListener("click", () => {
  const points = $("#talkingPoints").querySelectorAll("li");
  points.forEach((point, index) => { point.hidden = index === 1; });
  $("#shorterButton").textContent = "Shortened";
  $("#shorterButton").disabled = true;
  showToast("Condensed to two beats");
});

$("#costButton").addEventListener("click", () => $("#costDialog").showModal());

let elapsedSeconds = 24 * 60 + 18;
setInterval(() => {
  elapsedSeconds += 1;
  const minutes = Math.floor(elapsedSeconds / 60);
  const seconds = String(elapsedSeconds % 60).padStart(2, "0");
  $("#elapsedTime").textContent = `${minutes}:${seconds}`;
}, 1000);
