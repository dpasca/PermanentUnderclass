const $ = (selector) => document.querySelector(selector);

const eventNames = [
  "session.status",
  "transcript.partial",
  "transcript.final",
  "transcript.revised",
  "transcript.cleared",
  "reference.status",
  "usage.updated",
  "assistant.working",
  "assistant.suggestion",
  "assistant.failed",
  "assistant.state",
  "stream.reset"
];

const mockScenarios = [
  {
    question: "“Tell me about a time you improved the performance of a critical system.”",
    lead: "Lead with the checkout latency story",
    points: [
      ["Set the stakes.", "Checkout p95 had climbed to 1.8 seconds during peak traffic and was starting to affect conversion."],
      ["Name your move.", "I traced the path across services, found an N+1 lookup, and proposed a request-scoped batcher."],
      ["Land the result.", "We brought p95 down by 41%, held the gain through holiday load, and added a latency budget."]
    ],
    proof: [["41%", "p95 latency reduction"], ["18k", "peak requests / minute"], ["0", "regressions over 6 months"]],
    watchTitle: "They may ask what you personally owned",
    watchBody: "Be precise: you led diagnosis and rollout; the inventory team owned the service-side API change.",
    followup: "“How did you prove the cache would not return stale inventory?”"
  },
  {
    question: "“What did you learn when that launch did not go to plan?”",
    lead: "Use the rollout incident—then show the changed habit",
    points: [
      ["Own the miss.", "I optimized for the happy path and underestimated how slowly older clients would drain."],
      ["Show your response.", "I paused the rollout, wrote the compatibility shim, and kept everyone on one incident timeline."],
      ["Name the lesson.", "Every later migration shipped with rollback criteria and a rehearsed mixed-version test."]
    ],
    proof: [["27 min", "to halt the rollout"], ["2 days", "to safe relaunch"], ["100%", "later migrations rehearsed"]],
    watchTitle: "Avoid making the story sound too polished",
    watchBody: "Say what you missed before explaining the recovery. The learning is stronger when the mistake is concrete.",
    followup: "“How did you rebuild confidence with the teams affected?”"
  }
];

const state = {
  mode: "connecting",
  connectionKind: "connecting",
  snapshot: null,
  stream: null,
  cursor: null,
  reconnectStartSequence: null,
  replayedDuringReconnect: 0,
  lastHeartbeatAt: 0,
  resyncing: false,
  currentCitationPath: "",
  mockIndex: 0,
  mockElapsedSeconds: 24 * 60 + 18
};

let toastTimer;
let recoveryTimer;

function showToast(message) {
  const toast = $("#toast");
  toast.textContent = message;
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toast.hidden = true; }, 1800);
}

function formatCurrency(value) {
  const places = value > 0 && value < 0.01 ? 4 : 2;
  return `$${Number(value || 0).toFixed(places)}`;
}

function formatDuration(seconds) {
  const minutes = Number(seconds || 0) / 60;
  return minutes < 1 ? `${Math.round(Number(seconds || 0))} sec` : `${minutes.toFixed(1)} min`;
}

function formatTime(dateValue) {
  const date = new Date(dateValue);
  if (Number.isNaN(date.getTime())) return "now";
  return new Intl.DateTimeFormat([], {
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit"
  }).format(date);
}

function setConnectionStatus(kind, label, eyebrow = null) {
  state.connectionKind = kind;
  const chip = $("#connectionButton");
  chip.classList.remove("is-connected", "is-reconnecting");
  if (kind === "connected") chip.classList.add("is-connected");
  if (kind === "reconnecting") chip.classList.add("is-reconnecting");
  $("#connectionEyebrow").textContent = eyebrow || (kind === "connected" ? "CAUGHT UP" : "RECONNECTING");
  $("#connectionLabel").textContent = label;
  renderInferenceStatus();
}

function setInferenceStatus(kind, eyebrow, title, detail, checkCount = null) {
  const panel = $("#inferenceStatus");
  if (!panel) return;
  panel.className = `inference-status is-${kind}`;
  $("#inferenceEyebrow").textContent = eyebrow;
  $("#inferenceTitle").textContent = title;
  $("#inferenceDetail").textContent = detail;
  const count = $("#inferenceCount");
  count.hidden = checkCount === null;
  if (checkCount !== null) {
    count.textContent = `${checkCount.toLocaleString()} model check${checkCount === 1 ? "" : "s"}`;
  }
}

function renderInferenceStatus() {
  const snapshot = state.snapshot;
  const session = snapshot?.session;
  const assistant = snapshot?.assistant;
  const reference = snapshot?.reference;
  const checkCount = snapshot?.usage?.assistantGenerations ?? 0;
  const hasLocalReferences = reference?.phase === "ready" && reference?.documentCount > 0;

  if (state.mode === "mock") {
    setInferenceStatus(
      "off",
      "PREVIEW ONLY · INFERENCE OFF",
      "No inference is happening",
      "These cards are canned examples. Start the Mac app for live transcript analysis."
    );
    return;
  }

  if (state.mode !== "live" || !snapshot) {
    setInferenceStatus(
      "connecting",
      "VERIFYING INFERENCE",
      "Checking the Mac host…",
      "Guidance will not be labeled live until the host state is verified."
    );
    return;
  }

  if (state.connectionKind !== "connected") {
    setInferenceStatus(
      "delayed",
      "HOST STATUS DELAYED",
      "This display is reconnecting",
      "The Mac may keep analyzing, but this page cannot verify new inference until it catches up.",
      checkCount
    );
    return;
  }

  if (session?.suggestionsPaused) {
    setInferenceStatus(
      "off",
      "INFERENCE PAUSED",
      "No inference is happening",
      "Transcript capture continues, but completed turns are not sent to the assistant.",
      checkCount
    );
    return;
  }

  if (!session?.isListening) {
    setInferenceStatus(
      "off",
      "CAPTURE STOPPED · INFERENCE OFF",
      "No inference is happening",
      "Start meeting capture in the Mac app to analyze completed turns.",
      checkCount
    );
    return;
  }

  if (assistant?.phase === "unavailable") {
    setInferenceStatus(
      "blocked",
      "INFERENCE UNAVAILABLE",
      "No inference is happening",
      assistant.lastError || "Assistant setup is incomplete on the Mac.",
      checkCount
    );
    return;
  }

  if (assistant?.phase === "failed") {
    setInferenceStatus(
      "failed",
      "INFERENCE FAILED",
      "The latest model check failed",
      assistant.lastError || "Transcript capture continues while the assistant needs attention.",
      checkCount
    );
    return;
  }

  if (assistant?.phase === "working") {
    setInferenceStatus(
      hasLocalReferences ? "working" : "general",
      hasLocalReferences ? "INFERENCE RUNNING NOW" : "INFERENCE RUNNING · GENERAL KNOWLEDGE",
      hasLocalReferences ? "Analyzing the latest completed turn" : "Analyzing without local supporting material",
      hasLocalReferences
        ? "A locally grounded model decision is in progress. Turns from both speakers are eligible."
        : "The result will be clearly labeled and should be verified before relying on it.",
      checkCount
    );
    return;
  }

  if (assistant?.phase === "ready" && assistant.suggestion) {
    const usesGeneralKnowledge = assistant.suggestion.grounding === "generalKnowledge"
      || !(assistant.suggestion.citations || []).length;
    setInferenceStatus(
      usesGeneralKnowledge ? "general" : "active",
      usesGeneralKnowledge
        ? "INFERENCE ACTIVE · GENERAL KNOWLEDGE"
        : "INFERENCE ACTIVE · LOCALLY GROUNDED",
      usesGeneralKnowledge
        ? "Guidance ready without local support"
        : "The latest model check produced locally grounded guidance",
      usesGeneralKnowledge
        ? "The suggestion is prefixed as unverified general model knowledge."
        : `Based on event #${assistant.suggestion.basedOnSequence.toLocaleString()} · both speakers remain eligible.`,
      checkCount
    );
    return;
  }

  if (assistant?.lastEvaluationOutcome === "noSuggestion") {
    const checkedAt = assistant.lastEvaluationAt
      ? ` at ${formatTime(assistant.lastEvaluationAt)}`
      : "";
    setInferenceStatus(
      hasLocalReferences ? "active" : "general",
      "INFERENCE ACTIVE · LATEST TURN CHECKED",
      "The model ran and chose not to interrupt",
      `Latest completed turn checked${checkedAt}. ${hasLocalReferences ? "Local material was available." : "General-knowledge fallback was available."}`,
      checkCount
    );
    return;
  }

  if (hasLocalReferences) {
    setInferenceStatus(
      "armed",
      "INFERENCE ARMED · LOCAL REFERENCES READY",
      "Waiting for a completed turn",
      "Your speech and the other speaker are both checked after each finalized turn.",
      checkCount
    );
  } else {
    setInferenceStatus(
      "general",
      "INFERENCE ARMED · GENERAL KNOWLEDGE",
      "No local supporting material",
      "The assistant will still suggest an answer and prefix it as general model knowledge.",
      checkCount
    );
  }
}

function showRecovery(title, detail, recovered = false) {
  const banner = $("#recoveryBanner");
  banner.hidden = false;
  banner.classList.toggle("is-recovered", recovered);
  $("#recoveryTitle").textContent = title;
  $("#recoveryDetail").textContent = detail;
  clearTimeout(recoveryTimer);
  if (recovered) recoveryTimer = setTimeout(() => { banner.hidden = true; }, 2300);
}

function updateWatermark(replayed = null) {
  const sequence = state.cursor?.sequence ?? 0;
  $("#popoverLastEvent").textContent = `#${sequence.toLocaleString()}`;
  const replayDetail = replayed === null
    ? `Event ${sequence.toLocaleString()} · live loopback`
    : `Event ${sequence.toLocaleString()} · ${replayed} event${replayed === 1 ? "" : "s"} replayed`;
  $("#resumeWatermark").innerHTML = `
    <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M4 10l4 4 8-9"/></svg>
    <span><strong>Everything received</strong><small>${replayDetail}</small></span>
  `;
}

function renderSession(session) {
  if (!session) return;
  $("#assistantToggle").checked = !session.suggestionsPaused;
  $("#assistantState").textContent = session.suggestionsPaused
    ? "Transcript only"
    : (session.isListening ? "Checking every completed turn" : "Inference stops with capture");
  const liveMeta = $(".transcript-meta span:first-child");
  liveMeta.innerHTML = `<i></i> ${session.isListening ? "Live" : "Stopped"}`;
  renderAssistant(state.snapshot?.assistant, session.suggestionsPaused);
  renderInferenceStatus();
}

function renderReference(reference) {
  if (!reference) return;
  $("#referenceFolderName").textContent = reference.folderName;
  const revision = reference.revision ? ` · rev ${reference.revision.slice(0, 8)}` : "";
  const warning = reference.issueCount ? ` · ${reference.issueCount} warning${reference.issueCount === 1 ? "" : "s"}` : "";
  $("#referenceFolderDetail").textContent = `${reference.documentCount} document${reference.documentCount === 1 ? "" : "s"}${revision}${warning}`;
  $("#referenceWatchTitle").textContent = reference.isWatching ? "Watched by this Mac" : "Host reference status";
  $("#referenceWatchDetail").textContent = reference.phase === "scanning"
    ? "Indexing local changes…"
    : reference.phase === "ready"
      ? "Changes are ingested automatically"
      : reference.configured
        ? "Local grounding unavailable · general fallback stays on"
        : "Optional · general fallback stays on";
  const readyIndicator = $(".source-ready");
  const isReady = reference.phase === "ready" && reference.documentCount > 0;
  readyIndicator.classList.toggle("is-ready", isReady);
  readyIndicator.classList.toggle("is-scanning", reference.phase === "scanning");
  readyIndicator.setAttribute(
    "aria-label",
    isReady ? "Ready" : reference.phase === "scanning" ? "Indexing" : "Not ready"
  );
  renderInferenceStatus();
}

function renderUsage(usage) {
  if (!usage) return;
  const total = formatCurrency(usage.estimatedTranscriptionCostUSD);
  $("#sessionCost").textContent = total;
  $("#costDialogTotal").textContent = total;
  $("#liveUsageDetail").textContent = `2 tracks · ${formatDuration(usage.liveAudioSeconds)}`;
  $("#liveUsageCost").textContent = formatCurrency(usage.estimatedLiveTranscriptionCostUSD);
  $("#finalUsageDetail").textContent = `GPT-Transcribe · ${formatDuration(usage.finalAudioSeconds)}`;
  $("#finalUsageCost").textContent = formatCurrency(usage.estimatedFinalTranscriptionCostUSD);
  const cache = usage.assistantCachedInputTokens
    ? ` · ${usage.assistantCachedInputTokens.toLocaleString()} cached`
    : "";
  $("#assistantUsageDetail").textContent = `${usage.assistantGenerations} generations · ${usage.assistantInputTokens.toLocaleString()} input / ${usage.assistantOutputTokens.toLocaleString()} output / ${usage.assistantReasoningTokens.toLocaleString()} reasoning tokens${cache}`;
  $("#assistantUsageCost").textContent = "tracked";
  renderInferenceStatus();
}

function createTurn(turn, partial = false) {
  const article = document.createElement("article");
  const isYou = turn.speaker === "you";
  article.className = `turn ${isYou ? "you" : "interviewer"}${partial ? " partial-turn" : ""}`;

  const header = document.createElement("header");
  const avatar = document.createElement("span");
  avatar.className = "speaker-avatar";
  avatar.textContent = isYou ? "YOU" : "OT";
  const speaker = document.createElement("strong");
  speaker.textContent = isYou ? "You" : "Other";
  const time = document.createElement("time");
  time.textContent = partial ? "now" : formatTime(turn.startedAt);
  header.append(avatar, speaker, time);

  const paragraph = document.createElement("p");
  paragraph.textContent = turn.text;
  if (partial) {
    const caret = document.createElement("span");
    caret.className = "partial-caret";
    paragraph.append(caret);
  }
  article.append(header, paragraph);
  return article;
}

function renderTranscript(transcript) {
  const container = $("#transcriptScroll");
  container.replaceChildren();
  const turns = transcript?.turns || [];
  const partials = transcript?.partials || [];
  if (!turns.length && !partials.length) {
    const empty = document.createElement("article");
    empty.className = "turn";
    const text = document.createElement("p");
    text.textContent = "Transcript turns will appear here when meeting capture starts.";
    empty.append(text);
    container.append(empty);
    return;
  }
  if (turns.length) {
    const divider = document.createElement("div");
    divider.className = "time-divider";
    const label = document.createElement("span");
    label.textContent = formatTime(turns[0].startedAt).replace(/:\d{2}(?=\s|$)/, "");
    divider.append(label);
    container.append(divider);
  }
  turns.forEach((turn) => container.append(createTurn(turn)));
  partials.filter((partial) => partial.text).forEach((partial) => container.append(createTurn(partial, true)));
  requestAnimationFrame(() => { container.scrollTop = container.scrollHeight; });
}

function replaceTalkingPoints(points) {
  const list = $("#talkingPoints");
  list.replaceChildren();
  points.forEach((point, index) => {
    const item = document.createElement("li");
    const number = document.createElement("span");
    number.textContent = String(index + 1).padStart(2, "0");
    const text = document.createElement("p");
    const title = document.createElement("strong");
    title.textContent = point.title;
    text.append(title, document.createTextNode(` ${point.body}`));
    item.append(number, text);
    list.append(item);
  });
}

function replaceProof(points) {
  const list = $("#proofList");
  list.replaceChildren();
  points.forEach((point) => {
    const item = document.createElement("li");
    const value = document.createElement("strong");
    value.textContent = point.value;
    const label = document.createElement("span");
    label.textContent = point.label;
    item.append(value, label);
    list.append(item);
  });
}

function setGuidanceVisibility(visible) {
  $("#listeningStrip").hidden = !visible;
  $("#answerCard").hidden = !visible;
  $("#evidenceGrid").hidden = !visible;
  $("#nextQuestionCard").hidden = !visible;
}

function renderAssistant(assistant, paused = state.snapshot?.session?.suggestionsPaused) {
  renderInferenceStatus();
  const empty = $("#pausedState");
  if (paused) {
    setGuidanceVisibility(false);
    empty.hidden = false;
    $("#emptyStateSymbol").textContent = "Ⅱ";
    $("#emptyStateTitle").textContent = "Live suggestions paused";
    $("#emptyStateDetail").textContent = "The transcript is still arriving. Resume suggestions whenever you want help.";
    return;
  }

  if (assistant?.phase === "working") {
    setGuidanceVisibility(false);
    $("#listeningStrip").hidden = false;
    $("#questionText").textContent = "Analyzing the latest completed turn…";
    empty.hidden = true;
    $("#assistantState").textContent = "Generating guidance";
    return;
  }

  if (assistant?.phase === "failed" || assistant?.phase === "unavailable") {
    setGuidanceVisibility(false);
    empty.hidden = false;
    $("#emptyStateSymbol").textContent = "!";
    $("#emptyStateTitle").textContent = assistant.phase === "unavailable" ? "Assistant setup needed" : "Assistant needs attention";
    $("#emptyStateDetail").textContent = assistant.lastError || "The transcript continues while the assistant recovers.";
    return;
  }

  const suggestion = assistant?.suggestion;
  if (!suggestion) {
    setGuidanceVisibility(false);
    empty.hidden = false;
    const session = state.snapshot?.session;
    const reference = state.snapshot?.reference;
    const checkedWithoutGuidance = assistant?.lastEvaluationOutcome === "noSuggestion";
    if (!session?.isListening) {
      $("#emptyStateSymbol").textContent = "■";
      $("#emptyStateTitle").textContent = "Meeting capture is stopped";
      $("#emptyStateDetail").textContent = "Start listening in the Mac app to enable live inference.";
    } else {
      const hasLocalReferences = reference?.phase === "ready" && reference?.documentCount > 0;
      $("#emptyStateSymbol").textContent = checkedWithoutGuidance ? "✓" : "AI";
      $("#emptyStateTitle").textContent = checkedWithoutGuidance
        ? "Latest turn checked"
        : "Waiting for a completed turn";
      $("#emptyStateDetail").textContent = checkedWithoutGuidance
        ? "The model ran and found no useful interruption. Both speakers remain eligible."
        : hasLocalReferences
          ? "Your speech and the other speaker will both receive a locally grounded model check."
          : "No local supporting material is loaded. General-knowledge suggestions will be clearly labeled.";
    }
    return;
  }

  empty.hidden = true;
  setGuidanceVisibility(true);
  $("#questionText").textContent = suggestion.question;
  $("#answerLead").textContent = suggestion.lead;
  $("#watchTitle").textContent = suggestion.watchoutTitle;
  $("#watchBody").textContent = suggestion.watchoutBody;
  $("#followupText").textContent = suggestion.followup;
  $("#confidenceLabel").innerHTML = `<i></i> ${suggestion.confidence} confidence`;
  replaceTalkingPoints(suggestion.talkingPoints || []);
  replaceProof(suggestion.proof || []);
  const citationCount = (suggestion.citations || []).length;
  const usesGeneralKnowledge = suggestion.grounding === "generalKnowledge" || citationCount === 0;
  $("#answerCard").classList.toggle("uses-general-knowledge", usesGeneralKnowledge);
  $("#groundingNotice").hidden = !usesGeneralKnowledge;
  $("#proofHeading").textContent = usesGeneralKnowledge ? "FACTS TO VERIFY" : "PROOF TO USE";
  $("#groundingLabel").lastChild.textContent = usesGeneralKnowledge
    ? " General model knowledge · not locally supported"
    : ` Grounded in ${citationCount} Mac-hosted reference${citationCount === 1 ? "" : "s"}`;
  $("#generationTime").textContent = `generated in ${suggestion.generationMilliseconds.toLocaleString()} ms`;
  const citation = suggestion.citations?.[0];
  state.currentCitationPath = citation?.path || "";
  $("#sourceCitationText").textContent = citation ? `${citation.label} · ${citation.path}` : "";
  $("#sourceCitation").hidden = !citation;
  $("#pinButton").classList.toggle("is-active", assistant.pinnedSuggestionID === suggestion.id);
  $("#shorterButton").textContent = "Make shorter";
  $("#shorterButton").disabled = false;
  $("#talkingPoints").querySelectorAll("li").forEach((point) => { point.hidden = false; });
  $("#answerCard").animate(
    [{ opacity: 0.45, transform: "translateY(5px)" }, { opacity: 1, transform: "translateY(0)" }],
    { duration: 260, easing: "ease-out" }
  );
}

function renderSnapshot(snapshot) {
  state.snapshot = snapshot;
  state.cursor = { streamId: snapshot.streamId, sequence: snapshot.watermark };
  renderSession(snapshot.session);
  renderReference(snapshot.reference);
  renderUsage(snapshot.usage);
  renderTranscript(snapshot.transcript);
  renderAssistant(snapshot.assistant, snapshot.session.suggestionsPaused);
  updateWatermark();
}

function upsertByID(items, value) {
  const index = items.findIndex((item) => item.id === value.id);
  if (index === -1) items.push(value);
  else items[index] = value;
}

function applyEnvelope(envelope) {
  state.lastHeartbeatAt = Date.now();
  if (!state.snapshot || envelope.streamId !== state.snapshot.streamId) {
    void resyncSnapshot("producer changed");
    return;
  }
  if (envelope.name === "stream.reset") {
    void resyncSnapshot(envelope.payload?.reason || "stream reset");
    return;
  }
  if (envelope.sequence <= state.cursor.sequence) return;
  if (envelope.sequence !== state.cursor.sequence + 1) {
    void resyncSnapshot("event gap detected");
    return;
  }

  const payload = envelope.payload;
  switch (envelope.name) {
    case "session.status":
      state.snapshot.session = payload;
      renderSession(payload);
      break;
    case "transcript.partial":
      state.snapshot.transcript.partials = state.snapshot.transcript.partials.filter((item) => item.id !== payload.id);
      if (payload.text) state.snapshot.transcript.partials.push(payload);
      renderTranscript(state.snapshot.transcript);
      break;
    case "transcript.final":
    case "transcript.revised":
      upsertByID(state.snapshot.transcript.turns, payload);
      state.snapshot.transcript.turns.sort((a, b) => new Date(a.startedAt) - new Date(b.startedAt) || a.id.localeCompare(b.id));
      state.snapshot.transcript.partials = state.snapshot.transcript.partials.filter((item) => item.id !== payload.id);
      renderTranscript(state.snapshot.transcript);
      break;
    case "transcript.cleared":
      state.snapshot.transcript = payload;
      renderTranscript(payload);
      break;
    case "reference.status":
      state.snapshot.reference = payload;
      renderReference(payload);
      break;
    case "usage.updated":
      state.snapshot.usage = payload;
      renderUsage(payload);
      break;
    case "assistant.working":
      state.snapshot.assistant.phase = "working";
      state.snapshot.assistant.lastError = null;
      state.snapshot.assistant.evaluatingSequence = payload.basedOnSequence;
      renderAssistant(state.snapshot.assistant);
      break;
    case "assistant.suggestion":
      state.snapshot.assistant.phase = "ready";
      state.snapshot.assistant.suggestion = payload;
      state.snapshot.assistant.lastError = null;
      state.snapshot.assistant.evaluatingSequence = null;
      state.snapshot.assistant.lastEvaluatedSequence = payload.basedOnSequence;
      state.snapshot.assistant.lastEvaluationAt = payload.generatedAt;
      state.snapshot.assistant.lastEvaluationOutcome = "suggestion";
      renderAssistant(state.snapshot.assistant);
      break;
    case "assistant.failed":
      state.snapshot.assistant.phase = payload.phase || "failed";
      state.snapshot.assistant.lastError = payload.message;
      state.snapshot.assistant.evaluatingSequence = null;
      renderAssistant(state.snapshot.assistant);
      break;
    case "assistant.state":
      state.snapshot.assistant = payload;
      renderAssistant(payload);
      break;
    default:
      break;
  }
  state.cursor = { streamId: envelope.streamId, sequence: envelope.sequence };
  state.snapshot.watermark = envelope.sequence;
  if (state.reconnectStartSequence !== null) state.replayedDuringReconnect += 1;
  updateWatermark();
}

async function fetchSnapshot() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 3000);
  let response;
  try {
    response = await fetch("/v1/snapshot", {
      cache: "no-store",
      signal: controller.signal
    });
  } finally {
    clearTimeout(timeout);
  }
  if (!response.ok || !(response.headers.get("content-type") || "").includes("application/json")) {
    throw new Error(`Host snapshot unavailable (${response.status})`);
  }
  const snapshot = await response.json();
  if (snapshot.v !== 1 || !snapshot.streamId) throw new Error("Unsupported host protocol");
  return snapshot;
}

function openEventStream() {
  state.stream?.close();
  const cursor = `${state.cursor.streamId}:${state.cursor.sequence}`;
  const stream = new EventSource(`/v1/events?cursor=${encodeURIComponent(cursor)}`);
  state.stream = stream;
  stream.onopen = () => {
    state.lastHeartbeatAt = Date.now();
    setConnectionStatus("connected", "Connected to this Mac", "CAUGHT UP");
    $("#modeRibbon").textContent = "LIVE LOOPBACK · host-owned assistant · replayable SSE";
    if (state.reconnectStartSequence !== null) {
      const resumedAfter = state.reconnectStartSequence;
      setTimeout(() => {
        if (state.stream !== stream || state.reconnectStartSequence !== resumedAfter) return;
        const replayed = state.replayedDuringReconnect;
        updateWatermark(replayed);
        showRecovery(
          "Back online · nothing lost",
          `Resumed after #${resumedAfter.toLocaleString()} and replayed ${replayed} event${replayed === 1 ? "" : "s"}.`,
          true
        );
        state.reconnectStartSequence = null;
        state.replayedDuringReconnect = 0;
      }, 300);
    } else {
      updateWatermark();
    }
  };
  stream.onerror = () => {
    if (state.stream !== stream || state.resyncing) return;
    if (state.reconnectStartSequence === null) {
      state.reconnectStartSequence = state.cursor.sequence;
      state.replayedDuringReconnect = 0;
    }
    setConnectionStatus("reconnecting", `Resuming after #${state.cursor.sequence.toLocaleString()}`);
    showRecovery("Connection interrupted", "The Mac keeps recording. Reconnecting…");
  };
  eventNames.forEach((name) => {
    stream.addEventListener(name, (event) => {
      try {
        applyEnvelope(JSON.parse(event.data));
      } catch (error) {
        console.error("Could not apply companion event", error);
        void resyncSnapshot("unreadable event");
      }
    });
  });
  stream.addEventListener("heartbeat", () => {
    state.lastHeartbeatAt = Date.now();
  });
}

async function resyncSnapshot(reason) {
  if (state.resyncing || state.mode !== "live") return;
  state.resyncing = true;
  state.stream?.close();
  setConnectionStatus("reconnecting", "Refreshing host snapshot", "RESYNCING");
  showRecovery("Refreshing live state", `${reason}; requesting an atomic snapshot from the Mac…`);
  try {
    const snapshot = await fetchSnapshot();
    renderSnapshot(snapshot);
    openEventStream();
  } catch (error) {
    setTimeout(() => { state.resyncing = false; void resyncSnapshot(reason); }, 1000);
    return;
  }
  state.resyncing = false;
}

async function enterLiveMode() {
  const snapshot = await fetchSnapshot();
  state.mode = "live";
  $("#nextMomentButton").hidden = true;
  renderSnapshot(snapshot);
  openEventStream();
}

function renderMockScenario(index) {
  const scenario = mockScenarios[index];
  $("#questionText").textContent = scenario.question;
  $("#answerLead").textContent = scenario.lead;
  $("#watchTitle").textContent = scenario.watchTitle;
  $("#watchBody").textContent = scenario.watchBody;
  $("#followupText").textContent = scenario.followup;
  replaceTalkingPoints(scenario.points.map(([title, body]) => ({ title, body })));
  replaceProof(scenario.proof.map(([value, label]) => ({ value, label })));
  $("#answerCard").classList.remove("uses-general-knowledge");
  $("#groundingNotice").hidden = true;
  $("#proofHeading").textContent = "PROOF TO USE";
  $("#sourceCitation").hidden = false;
  setGuidanceVisibility(true);
  $("#pausedState").hidden = true;
}

function enterMockMode() {
  state.mode = "mock";
  $("#modeRibbon").textContent = "STANDALONE PREVIEW · simulated events (start the Swift app for live mode)";
  setConnectionStatus("connected", "Standalone preview", "SIMULATED");
  $("#nextMomentButton").hidden = false;
  renderMockScenario(0);
}

function testReconnect() {
  if (state.mode !== "live") {
    setConnectionStatus("reconnecting", "Simulating retry · 1.0 s");
    showRecovery("Connection interrupted", "Simulating host-side capture continuing…");
    setTimeout(() => {
      setConnectionStatus("connected", "Standalone preview", "SIMULATED");
      showRecovery("Back online · nothing lost", "Simulated replay completed.", true);
    }, 1600);
    return;
  }
  if (state.reconnectStartSequence !== null) return;
  state.reconnectStartSequence = state.cursor.sequence;
  state.replayedDuringReconnect = 0;
  state.stream?.close();
  setConnectionStatus("reconnecting", `Paused after #${state.cursor.sequence.toLocaleString()}`);
  showRecovery("Connection interrupted", "The Mac keeps recording. Reconnecting with the saved cursor…");
  setTimeout(openEventStream, 1600);
}

async function sendCommand(type, suggestionID = null) {
  if (state.mode !== "live") return { applied: true, message: "Preview action applied" };
  const key = globalThis.crypto?.randomUUID?.() || `cmd-${Date.now()}-${Math.random()}`;
  const body = JSON.stringify({ type, suggestionID });
  let lastError;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await fetch("/v1/commands", {
        method: "POST",
        headers: { "content-type": "application/json", "idempotency-key": key },
        body
      });
      if (!response.ok) throw new Error(`Command failed (${response.status})`);
      return await response.json();
    } catch (error) {
      lastError = error;
      if (attempt === 0) await new Promise((resolve) => setTimeout(resolve, 350));
    }
  }
  throw lastError;
}

function bindControls() {
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
  $("#simulateDropButton").addEventListener("click", testReconnect);
  $("#popoverDropButton").addEventListener("click", testReconnect);

  $("#assistantToggle").addEventListener("change", async (event) => {
    const active = event.target.checked;
    try {
      const result = await sendCommand(active ? "resumeSuggestions" : "pauseSuggestions");
      showToast(result.message);
      if (state.mode === "mock") {
        if (active) renderMockScenario(state.mockIndex);
        else renderAssistant(null, true);
      }
    } catch (error) {
      event.target.checked = !active;
      showToast(error.message);
    }
  });

  $("#nextMomentButton").addEventListener("click", () => {
    state.mockIndex = (state.mockIndex + 1) % mockScenarios.length;
    renderMockScenario(state.mockIndex);
    showToast("New simulated guidance generated");
  });
  document.addEventListener("keydown", (event) => {
    if (state.mode === "mock" && event.key.toLowerCase() === "n" && !event.metaKey && !event.ctrlKey && !event.altKey) {
      $("#nextMomentButton").click();
    }
  });

  $("#pinButton").addEventListener("click", async (event) => {
    const button = event.currentTarget;
    const isPinned = button.classList.contains("is-active");
    const suggestionID = state.snapshot?.assistant?.suggestion?.id;
    try {
      const result = await sendCommand(isPinned ? "unpinSuggestion" : "pinSuggestion", suggestionID);
      if (result.applied) button.classList.toggle("is-active", !isPinned);
      showToast(result.message);
    } catch (error) {
      showToast(error.message);
    }
  });

  $("#dismissButton").addEventListener("click", async () => {
    const suggestionID = state.snapshot?.assistant?.suggestion?.id;
    try {
      const result = await sendCommand("dismissSuggestion", suggestionID);
      showToast(result.message);
    } catch (error) {
      showToast(error.message);
    }
  });

  $("#copyButton").addEventListener("click", async () => {
    const answerParts = [
      $("#answerLead").textContent,
      ...Array.from($("#talkingPoints").querySelectorAll("p")).map((item) => item.textContent)
    ];
    if ($("#answerCard").classList.contains("uses-general-knowledge")) {
      answerParts.unshift(
        "NO LOCAL SUPPORTING MATERIAL — Uses the live discussion and general model knowledge; verify before relying on it."
      );
    }
    const answer = answerParts.join("\n\n");
    try {
      await navigator.clipboard.writeText(answer);
      showToast("Copied answer");
    } catch {
      showToast("Copy is unavailable in this browser");
    }
  });

  $("#shorterButton").addEventListener("click", () => {
    const points = $("#talkingPoints").querySelectorAll("li");
    points.forEach((point, index) => { point.hidden = index === 1; });
    $("#shorterButton").textContent = "Shortened";
    $("#shorterButton").disabled = true;
    showToast("Condensed locally to two beats");
  });
  $("#sourceCitation").addEventListener("click", () => {
    showToast(state.currentCitationPath || "Citation metadata unavailable");
  });
  $("#costButton").addEventListener("click", () => $("#costDialog").showModal());
}

function updateElapsedTime() {
  let elapsed = state.mockElapsedSeconds;
  const startedAt = state.snapshot?.session?.startedAt;
  if (state.mode === "live") {
    const endedAt = state.snapshot?.session?.endedAt;
    const end = endedAt ? new Date(endedAt).getTime() : Date.now();
    elapsed = startedAt ? Math.max(0, Math.floor((end - new Date(startedAt).getTime()) / 1000)) : 0;
  } else {
    state.mockElapsedSeconds += 1;
  }
  const minutes = Math.floor(elapsed / 60);
  const seconds = String(elapsed % 60).padStart(2, "0");
  $("#elapsedTime").textContent = `${minutes}:${seconds}`;
}

async function initialize() {
  bindControls();
  setConnectionStatus("reconnecting", "Finding PUnderclass on this Mac", "CONNECTING");
  try {
    await enterLiveMode();
  } catch (error) {
    console.info("Native host unavailable; using standalone prototype", error);
    enterMockMode();
  }
  updateElapsedTime();
  setInterval(updateElapsedTime, 1000);
  setInterval(() => {
    if (
      state.mode === "live"
        && state.stream?.readyState === EventSource.OPEN
        && state.lastHeartbeatAt
        && Date.now() - state.lastHeartbeatAt > 15_000
        && state.reconnectStartSequence === null
    ) {
      testReconnect();
    }
  }, 2500);
}

void initialize();
