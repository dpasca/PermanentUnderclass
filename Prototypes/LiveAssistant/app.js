const $ = (selector) => document.querySelector(selector);

const eventNames = [
  "session.status",
  "transcript.partial",
  "transcript.final",
  "transcript.revised",
  "transcript.cleared",
  "reference.status",
  "usage.updated",
  "assistant.bridge",
  "assistant.working",
  "assistant.suggestion",
  "assistant.failed",
  "assistant.state",
  "stream.reset"
];

const mockScenarios = [
  {
    question: "“Tell me about a time you improved the performance of a critical system.”",
    candidateStart: "Yeah—the clearest one is probably our checkout path...",
    preamble: "The clearest example is our checkout path, where the slowdown was already affecting conversion.",
    beats: [
      { label: "What I tried", point: "I profiled it and found repeated inventory lookups." },
      { label: "Check", point: "I replayed real traffic and watched p95, not just averages." },
      { label: "Afterward", point: "I added a latency alert so the regression could not return quietly." }
    ],
    citation: "Projects/Checkout.md"
  },
  {
    question: "“What did you learn when that launch did not go to plan?”",
    candidateStart: "Honestly, that first rollout was messier than I expected...",
    preamble: "Honestly, that rollout was messier than I expected because I'd planned around the happy path.",
    beats: [
      { label: "First move", point: "I paused the rollout and added a compatibility layer." },
      { label: "Messy bit", point: "I got both teams debugging from the same timeline." },
      { label: "Now", point: "I now rehearse rollback and mixed-version cases before launch." }
    ],
    citation: "Projects/Rollout-retro.md"
  },
  {
    question: "“How do you decide when a low-latency system is ready to ship?”",
    candidateStart: "I start with what delay a person can actually feel...",
    preamble: "I start with the delay a person can actually feel, not an abstract latency target.",
    beats: [
      { label: "Break it down", point: "I measure capture, model, and display latency separately." },
      { label: "Try bad cases", point: "I replay awkward pauses and broken connections." },
      { label: "Good enough", point: "I ship when it feels fast without firing at the wrong time." }
    ],
    citation: "Projects/Audio-assistant.md"
  },
  {
    question: "“What tradeoff did you make to keep the assistant useful?”",
    candidateStart: "The awkward part was answering early without jumping in too soon...",
    preamble: "The awkward tradeoff was answering early without jumping in before the question was clear.",
    beats: [
      { label: "What I chose", point: "I started generation after a stable 800-millisecond pause." },
      { label: "Fallback", point: "I ran it again when the final turn arrived." },
      { label: "Still checking", point: "I still measured whether early cues were useful, not merely fast." }
    ],
    citation: "Architecture/Latency-harness.md"
  },
  {
    question: "“A CUDA kernel shows high occupancy but still runs slowly. What would you look at next?”",
    candidateStart: "I would not trust occupancy by itself; I would open Nsight Compute first...",
    preamble: "If occupancy is already high, I'd look past occupancy and open Nsight Compute.",
    beats: [
      { label: "Memory", point: "I would check coalescing, cache misses, and DRAM throughput." },
      { label: "Warp stalls", point: "I would use Nsight Compute to see why warps were stalled." },
      { label: "Then code", point: "I would inspect divergence, register spills, and expensive instructions." }
    ],
    citation: "Notes/CUDA-performance.md"
  },
  {
    question: "“Why might a tiled CUDA matrix multiply get slower when you increase the tile size?”",
    candidateStart: "My first guess is that the larger tile pushed resource use too far...",
    preamble: "My first guess is that the larger tile pushed resource use too far.",
    beats: [
      { label: "Residency", point: "I would check whether shared-memory use reduced residency." },
      { label: "Registers", point: "I would look for register pressure and local-memory spills." },
      { label: "I would test", point: "I would compare tile sizes and bank conflicts in Nsight." }
    ],
    citation: "Notes/CUDA-kernels.md"
  },
  {
    isWebSearchPreview: true,
    question: "“As of today, what is the latest stable CUDA Toolkit release, and what profiling change matters?”",
    candidateStart: "I would verify that against NVIDIA’s current release notes rather than trust memory...",
    preamble: "As of today, I'd verify both facts in NVIDIA's current release notes.",
    beats: [
      { label: "Current release", point: "I’d confirm the production release in NVIDIA’s current toolkit notes." },
      { label: "Profiler change", point: "I’d pull one documented profiling change from that same release." },
      { label: "Version check", point: "I’d separate toolkit, driver, and Nsight versions before answering." }
    ],
    citations: [
      {
        label: "NVIDIA CUDA Toolkit Release Notes",
        path: "https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html"
      }
    ],
    grounding: "webSearch",
    generationMilliseconds: 1_280,
    totalLatencyMilliseconds: 2_080
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
  currentSuggestion: null,
  visibleSuggestions: [],
  mockIndex: 0,
  mockGeneration: 0,
  mockHistory: [],
  renderedSuggestionID: null,
  fallbackTopicNumbers: new Map(),
  nextFallbackTopicNumber: 0,
  topicStartedAtByTopicID: new Map(),
  mockElapsedSeconds: 24 * 60 + 18
};

let toastTimer;
let recoveryTimer;
let currentStageFitFrame;

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

function formatElapsedClock(totalSeconds) {
  const elapsed = Math.max(0, Math.floor(Number(totalSeconds) || 0));
  const hours = Math.floor(elapsed / 3600);
  const minutes = Math.floor((elapsed % 3600) / 60);
  const seconds = String(elapsed % 60).padStart(2, "0");
  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, "0")}:${seconds}`;
  }
  return `${minutes}:${seconds}`;
}

function triggerLabel(trigger) {
  if (trigger === "partialTranscript") return "stable partial";
  if (trigger === "finalizedTurn") return "final turn";
  return "transcript moment";
}

function elapsedMilliseconds(startedAt, endedAt = Date.now()) {
  const start = new Date(startedAt).getTime();
  const end = typeof endedAt === "number" ? endedAt : new Date(endedAt).getTime();
  if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
  return Math.max(0, Math.round(end - start));
}

function setConnectionStatus(kind, label, eyebrow = null) {
  state.connectionKind = kind;
  const chip = $("#connectionButton");
  chip.classList.remove("is-connected", "is-reconnecting", "is-disconnected");
  if (kind === "connected") chip.classList.add("is-connected");
  if (kind === "reconnecting") chip.classList.add("is-reconnecting");
  if (kind === "disconnected") chip.classList.add("is-disconnected");
  $("#connectionEyebrow").textContent = eyebrow || (kind === "connected" ? "CAUGHT UP" : "RECONNECTING");
  $("#connectionLabel").textContent = kind === "connected"
    ? "Connected"
    : kind === "reconnecting" ? "Reconnecting" : "Offline";
  chip.setAttribute("aria-label", label);
  chip.title = label;
  const popover = $("#connectionPopover");
  popover.classList.toggle("is-connected", kind === "connected");
  $("#popoverConnectionLabel").textContent = label;
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
    count.textContent = `${checkCount.toLocaleString()} model call${checkCount === 1 ? "" : "s"}`;
  }
}

function renderInferenceStatus() {
  const snapshot = state.snapshot;
  const session = snapshot?.session;
  const assistant = snapshot?.assistant;
  const reference = snapshot?.reference;
  const checkCount = snapshot?.usage?.assistantModelCalls
    ?? snapshot?.usage?.assistantGenerations
    ?? 0;
  const hasLocalReferences = reference?.phase === "ready" && reference?.documentCount > 0;
  const meeting = session?.purpose === "meeting";
  const assistantName = meeting ? "Meeting Assistant" : "Answer Mirror";
  const otherSpeaker = meeting ? "other participant" : "interviewer";
  const plausibleRehearsal = session?.answerMode === "plausibleRehearsal";

  if (state.mode === "mock") {
    setInferenceStatus(
      "off",
      "PREVIEW ONLY · INFERENCE OFF",
      "No inference is happening",
      "These outlines are canned examples. Start the Mac app for live comparison."
    );
    return;
  }

  if (state.mode !== "live" || !snapshot) {
    setInferenceStatus(
      "connecting",
      "VERIFYING INFERENCE",
      "Checking the Mac host…",
      "Model outlines will not be labeled live until the host state is verified."
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

  if (session?.isPreparingSyntheticInterview) {
    setInferenceStatus(
      "working",
      meeting ? "BUILDING GENERATED MEETING" : "BUILDING GENERATED INTERVIEW",
      `Generating five ${meeting ? "meeting" : "interview"} exchanges from the indexed references`,
      session.status || "The replay will begin as soon as the document-grounded scenario is ready.",
      checkCount
    );
    return;
  }

  if (session?.suggestionsPaused) {
    setInferenceStatus(
      "off",
      "INFERENCE PAUSED",
      "No inference is happening",
      `Transcript capture continues, but ${otherSpeaker} moments are not sent to ${assistantName}.`,
      checkCount
    );
    return;
  }

  if (!session?.isListening) {
    setInferenceStatus(
      "off",
      "CAPTURE STOPPED · INFERENCE OFF",
      "No inference is happening",
      `Start a live ${meeting ? "meeting" : "interview"} or generated replay in the Mac app.`,
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

  if (assistant?.bridge) {
    const bridgeTime = Number.isFinite(assistant.bridge.generationMilliseconds)
      ? ` in ${assistant.bridge.generationMilliseconds.toLocaleString()} ms`
      : "";
    setInferenceStatus(
      "general",
      "EARLY BRIDGE · EXPERIMENTAL",
      `A fact-free opening is ready${bridgeTime}`,
      assistant.phase === "working"
        ? "The full Answer Mirror cue is still being drafted and will replace it."
        : "This came from partial interviewer speech and may be replaced as the question becomes clearer.",
      checkCount
    );
    return;
  }

  if (assistant?.phase === "working") {
    const trigger = triggerLabel(assistant.evaluatingTrigger);
    const startDelay = elapsedMilliseconds(
      assistant.evaluationTriggeredAt,
      assistant.evaluationStartedAt
    );
    const timing = startDelay === null
      ? `Triggered by the latest ${trigger}.`
      : `Triggered by the latest ${trigger}; inference started after ${startDelay.toLocaleString()} ms.`;
    setInferenceStatus(
      plausibleRehearsal ? "general" : hasLocalReferences ? "working" : "general",
      plausibleRehearsal
        ? "PLAUSIBLE REHEARSAL · VERIFY"
        : hasLocalReferences ? "INFERENCE RUNNING NOW" : "INFERENCE RUNNING · GENERAL KNOWLEDGE",
      hasLocalReferences
        ? `Drafting ${meeting ? "grounded response" : "comparison"} beats from the latest ${trigger}`
        : `Drafting an honest response outline from the latest ${trigger}`,
      hasLocalReferences
        ? `${timing} Only ${otherSpeaker} speech triggers a new answer outline.`
        : `${timing} The result will be clearly labeled and should be verified.`,
      checkCount
    );
    return;
  }

  if (assistant?.phase === "ready" && assistant.suggestion) {
    const suggestionIsPlausible = assistant.suggestion.answerMode === "plausibleRehearsal"
      || plausibleRehearsal;
    const usesGeneralKnowledge = assistant.suggestion.grounding === "generalKnowledge"
      || !(assistant.suggestion.citations || []).length;
    const repairedGrounding = assistant.lastEvaluationOutcome === "repairedGrounding"
      || assistant.suggestion.inferenceOutcome === "repairedGrounding";
    const repairMilliseconds = assistant.suggestion.groundingRepairMilliseconds;
    const repairDetail = repairedGrounding
      ? ` Grounding was corrected with one retry${Number.isFinite(repairMilliseconds) ? `, adding ${repairMilliseconds.toLocaleString()} ms` : ""}.`
      : "";
    setInferenceStatus(
      suggestionIsPlausible ? "general" : usesGeneralKnowledge ? "general" : "active",
      suggestionIsPlausible
        ? "PLAUSIBLE REHEARSAL · VERIFY"
        : usesGeneralKnowledge
        ? "INFERENCE ACTIVE · GENERAL KNOWLEDGE"
        : "INFERENCE ACTIVE · LOCALLY GROUNDED",
      suggestionIsPlausible
        ? "A project-specific rehearsal draft is ready"
        : usesGeneralKnowledge
        ? `${assistantName} outline ready without local support`
        : "A locally grounded answer outline is ready",
      suggestionIsPlausible
        ? `Unsupported details are rehearsal assumptions, even when a citation anchors the real project.${repairDetail}`
        : usesGeneralKnowledge
        ? meeting
          ? `The outline marks what should be verified and avoids invented project facts.${repairDetail}`
          : `The outline is approach-oriented and avoids unverified personal claims.${repairDetail}`
        : `Based on event #${assistant.suggestion.basedOnSequence.toLocaleString()} · compare it with your transcript on the right.${repairDetail}`,
      checkCount
    );
    return;
  }

  if (["notAnswerable", "noSuggestion"].includes(assistant?.lastEvaluationOutcome)) {
    const checkedAt = assistant.lastEvaluationAt
      ? ` at ${formatTime(assistant.lastEvaluationAt)}`
      : "";
    const latency = Number.isFinite(assistant.lastEvaluationLatencyMilliseconds)
      ? ` in ${assistant.lastEvaluationLatencyMilliseconds.toLocaleString()} ms`
      : "";
    setInferenceStatus(
      hasLocalReferences ? "active" : "general",
      "INFERENCE ACTIVE · LATEST TURN CHECKED",
      `The model ran but did not find a clear ${meeting ? "meeting" : "interview"} question`,
      `Latest ${triggerLabel(assistant.lastEvaluationTrigger)} checked${latency}${checkedAt}. ${hasLocalReferences ? "Local material was available." : "General-knowledge fallback was available."}`,
      checkCount
    );
    return;
  }

  if (hasLocalReferences) {
    setInferenceStatus(
      "armed",
      "INFERENCE ARMED · LOCAL REFERENCES READY",
      `Waiting for the ${otherSpeaker}`,
      `A ${otherSpeaker} pause can produce grounded shorthand beats; your own speech stays in the transcript.`,
      checkCount
    );
  } else {
    setInferenceStatus(
      "general",
      "INFERENCE ARMED · GENERAL KNOWLEDGE",
      "No local supporting material",
      `${meeting ? "Meeting questions" : "Interviewer moments"} can still produce clearly labeled, cautious response outlines.`,
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
  const synthetic = session.source === "syntheticInterview";
  const meeting = session.purpose === "meeting";
  const assistantAvailable = session.assistantAvailable !== false;
  $("#localTranscriptView").hidden = assistantAvailable;
  $("#currentStage").hidden = !assistantAvailable;
  $("#answerHistory").hidden = !assistantAvailable;
  if (!assistantAvailable) {
    $("#pausedState").hidden = true;
    $("#localTranscriptTitle").textContent = meeting
      ? "Meeting transcript"
      : "Interview transcript";
    $("#localTranscriptStatus").textContent = session.status
      || (session.isListening ? "Listening locally" : "Local capture is ready");
    $("#localLimitationsDetail").textContent = meeting
      ? "Text appears after each completed turn. Live partial words, Meeting Assistant cues, web search, and generated replays require an OpenAI API key."
      : "Text appears after each completed turn. Live partial words, Answer Mirror suggestions, web search, and generated replays require an OpenAI API key.";
  }
  $("#behaviorName").textContent = session.behaviorName
    || (meeting ? "Meeting assistant" : "Answer mirror");
  $("#behaviorDetail").textContent = session.behaviorDetail
    || (meeting
      ? "Ground concise response cues in the meeting references"
      : "Show 3–5 shorthand beats when the interviewer pauses");
  $("#assistantToggle").checked = !session.suggestionsPaused;
  $("#assistantState").textContent = session.isPreparingSyntheticInterview
    ? `Generating ${meeting ? "meeting" : "interview"} from references`
    : (session.suggestionsPaused
      ? "Transcript only"
      : (session.isListening
        ? `Waiting for ${meeting ? "meeting questions" : "interviewer pauses"}`
        : "Inference stops with capture"));
  $("#meetingTitle").textContent = session.title
    || (synthetic
      ? `Reference-grounded generated ${meeting ? "meeting" : "interview"}`
      : meeting ? "Live meeting" : "Live interview");
  if (state.mode === "live") {
    $("#modeRibbon").textContent = synthetic
      ? `GENERATED ${meeting ? "MEETING" : "INTERVIEW"} REPLAY · grounded in references · live response comparison`
      : meeting
        ? "LIVE MEETING · grounded Meeting Assistant · replayable SSE"
        : "LIVE INTERVIEW · host-owned assistant · replayable SSE";
  }
  const liveMeta = $(".transcript-meta span:first-child");
  const captureLabel = session.isPreparingSyntheticInterview
    ? "Preparing"
    : (session.isListening ? (synthetic ? "Generated replay" : "Live") : "Stopped");
  liveMeta.innerHTML = `<i></i> ${captureLabel}`;
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
  const checks = usage.assistantGenerations ?? 0;
  const calls = usage.assistantModelCalls ?? checks;
  const repairAttempts = usage.assistantGroundingRepairAttempts ?? 0;
  const repairSuccesses = usage.assistantGroundingRepairSuccesses ?? 0;
  const repairMilliseconds = usage.assistantGroundingRepairMilliseconds ?? 0;
  const repair = repairAttempts
    ? repairAttempts === repairSuccesses
      ? ` · ${repairSuccesses.toLocaleString()} grounding repair${repairSuccesses === 1 ? "" : "s"} (+${repairMilliseconds.toLocaleString()} ms)`
      : ` · ${repairSuccesses.toLocaleString()}/${repairAttempts.toLocaleString()} grounding repairs succeeded (+${repairMilliseconds.toLocaleString()} ms)`
    : "";
  $("#assistantUsageDetail").textContent = `${checks.toLocaleString()} checks · ${calls.toLocaleString()} model calls${repair} · ${(usage.assistantInputTokens ?? 0).toLocaleString()} input / ${(usage.assistantOutputTokens ?? 0).toLocaleString()} output / ${(usage.assistantReasoningTokens ?? 0).toLocaleString()} reasoning tokens${cache}`;
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
  const meeting = state.snapshot?.session?.purpose === "meeting";
  avatar.textContent = isYou ? "YOU" : meeting ? "OT" : "IV";
  const speaker = document.createElement("strong");
  speaker.textContent = isYou ? "You" : meeting ? "Other" : "Interviewer";
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

function renderTranscriptInto(container, transcript) {
  if (!container) return;
  container.replaceChildren();
  const turns = transcript?.turns || [];
  const partials = transcript?.partials || [];
  if (!turns.length && !partials.length) {
    const empty = document.createElement("article");
    empty.className = "turn empty-transcript";
    const text = document.createElement("p");
    text.textContent = state.snapshot?.session?.purpose === "meeting"
      ? "Transcript turns will appear here when meeting capture starts."
      : "Transcript turns will appear here when a live interview or generated replay starts.";
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

function renderTranscript(transcript) {
  renderTranscriptInto($("#transcriptScroll"), transcript);
  renderTranscriptInto($("#localTranscriptList"), transcript);
}

function answerHistoryFor(assistant) {
  const history = Array.isArray(assistant?.suggestionHistory)
    ? [...assistant.suggestionHistory]
    : [];
  const current = assistant?.suggestion;
  if (current && !history.some((item) => item.id === current.id)) {
    history.unshift(current);
  }
  const unique = [];
  history.forEach((item) => {
    if (item && !unique.some((candidate) => candidate.id === item.id)) {
      unique.push(item);
    }
  });
  return unique.slice(0, 4);
}

function topicIDFor(suggestion) {
  return suggestion?.topicID || suggestion?.id || "";
}

function fallbackTopicNumber(suggestion, suggestions) {
  [...suggestions].reverse().forEach((item) => {
    const topicID = topicIDFor(item);
    if (!topicID || state.fallbackTopicNumbers.has(topicID)) return;
    state.nextFallbackTopicNumber += 1;
    state.fallbackTopicNumbers.set(topicID, state.nextFallbackTopicNumber);
  });
  const topicID = topicIDFor(suggestion);
  if (!state.fallbackTopicNumbers.has(topicID)) {
    state.nextFallbackTopicNumber += 1;
    state.fallbackTopicNumbers.set(topicID, state.nextFallbackTopicNumber);
  }
  return state.fallbackTopicNumbers.get(topicID);
}

function renderTopicContext(suggestion, suggestions) {
  const context = $("#topicContext");
  context.hidden = !suggestion;
  if (!suggestion) return;

  const suppliedTopicNumber = Number(suggestion.topicNumber);
  const topicNumber = Number.isInteger(suppliedTopicNumber) && suppliedTopicNumber > 0
    ? suppliedTopicNumber
    : fallbackTopicNumber(suggestion, suggestions);
  $("#topicNumber").textContent = topicNumber.toLocaleString();

  const topicID = topicIDFor(suggestion);
  if (!state.topicStartedAtByTopicID.has(topicID)) {
    const topicTimes = suggestions
      .filter((item) => topicIDFor(item) === topicID)
      .map((item) => new Date(item.generatedAt).getTime())
      .filter(Number.isFinite);
    state.topicStartedAtByTopicID.set(
      topicID,
      topicTimes.length ? Math.min(...topicTimes) : Date.now()
    );
  }
  updateTopicElapsedTime();
}

function updateTopicElapsedTime() {
  const suggestion = state.currentSuggestion;
  if (!suggestion) return;
  const startedAt = state.topicStartedAtByTopicID.get(topicIDFor(suggestion));
  if (!Number.isFinite(startedAt)) return;
  const elapsed = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
  const topicNumber = $("#topicNumber").textContent;
  $("#topicElapsed").textContent = formatElapsedClock(elapsed);
  $("#topicContext").setAttribute(
    "aria-label",
    `Topic ${topicNumber}, elapsed ${formatDuration(elapsed)}`
  );
}

function replaceAnswerBeats(container, beats, previousBeats = []) {
  container.replaceChildren();
  const currentBeats = beats || [];
  const previousByCurrentIndex = currentBeats.map(() => []);
  previousBeats.forEach((beat, index) => {
    if (!previousByCurrentIndex.length) return;
    const targetIndex = Math.min(index, previousByCurrentIndex.length - 1);
    previousByCurrentIndex[targetIndex].push(beat);
  });

  currentBeats.forEach((beat, index) => {
    const item = document.createElement("li");
    const label = document.createElement("strong");
    label.textContent = beat.label;
    const point = document.createElement("span");
    point.className = "answer-beat-current";
    point.textContent = beat.point;
    item.append(label, point);

    previousByCurrentIndex[index].forEach((previousBeat) => {
      const previous = document.createElement("div");
      previous.className = "answer-beat-earlier";
      const previousLabel = document.createElement("small");
      previousLabel.textContent = "EARLIER";
      const previousPoint = document.createElement("span");
      previousPoint.textContent = previousBeat.point;
      previous.append(previousLabel, previousPoint);
      item.append(previous);
    });
    container.append(item);
  });
}

function previousVersionFor(suggestions, current) {
  const currentTopicID = topicIDFor(current);
  return suggestions.find((suggestion) => (
    suggestion
      && suggestion.id !== current?.id
      && topicIDFor(suggestion) === currentTopicID
  )) || null;
}

function previousEntriesFor(suggestions, current) {
  const currentTopicID = topicIDFor(current);
  return suggestions
    .filter((suggestion) => (
      suggestion
        && suggestion.id !== current?.id
        && topicIDFor(suggestion) !== currentTopicID
    ))
    .slice(0, 3);
}

function outlineText(suggestion) {
  if (!suggestion) return "";
  const assumptions = suggestion.answerMode === "plausibleRehearsal"
    && (suggestion.plausibleAssumptions || []).length
    ? `Verify: ${suggestion.plausibleAssumptions.join("; ")}`
    : null;
  return [
    suggestion.answerMode === "plausibleRehearsal"
      ? "[PLAUSIBLE REHEARSAL — VERIFY ASSUMPTIONS]"
      : null,
    suggestion.question,
    suggestion.preamble,
    ...(suggestion.beats || []).map((beat) => beat.point),
    assumptions
  ].filter(Boolean).join("\n");
}

function groundingText(suggestion) {
  const citationCount = (suggestion.citations || []).length;
  const usesGeneralKnowledge = suggestion.grounding === "generalKnowledge" || citationCount === 0;
  const usesWebSearch = suggestion.grounding === "webSearch" && citationCount > 0;
  const meeting = state.snapshot?.session?.purpose === "meeting";
  if (suggestion.answerMode === "plausibleRehearsal") {
    return "Plausible rehearsal draft · verify assumptions";
  }
  if (usesGeneralKnowledge) {
    return meeting
      ? "Needs verification · no project facts invented"
      : "Approach-oriented · no personal claims added";
  }
  return usesWebSearch
    ? `Grounded in ${citationCount} public web source${citationCount === 1 ? "" : "s"}`
    : `Grounded in ${citationCount} Mac-hosted reference${citationCount === 1 ? "" : "s"}`;
}

function generationTimingText(suggestion) {
  const assistantTime = Number(suggestion.generationMilliseconds || 0).toLocaleString();
  const totalTime = suggestion.totalLatencyMilliseconds;
  return Number.isFinite(totalTime)
    ? `assistant ${assistantTime} ms · transcript→cue ${totalTime.toLocaleString()} ms · ${triggerLabel(suggestion.trigger)}`
    : `assistant ${assistantTime} ms`;
}

function createWebCitationLinks(suggestion, className) {
  if (suggestion?.grounding !== "webSearch") return null;
  const citations = (suggestion.citations || []).filter((citation) => citation?.path);
  if (!citations.length) return null;
  const container = document.createElement("div");
  container.className = className;
  container.setAttribute("aria-label", "Public web sources");
  citations.forEach((citation, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "web-citation-link";
    button.dataset.citationPath = citation.path;
    button.title = citation.path;
    button.textContent = `Source ${index + 1} · ${citation.label || citation.path} ↗`;
    container.append(button);
  });
  return container;
}

function createHistoryRound(suggestion, index) {
  const round = document.createElement("article");
  round.className = "history-round";
  round.dataset.suggestionId = suggestion.id;

  const header = document.createElement("header");
  const eyebrow = document.createElement("small");
  const suppliedTopicNumber = Number(suggestion.topicNumber);
  const topicLabel = Number.isInteger(suppliedTopicNumber) && suppliedTopicNumber > 0
    ? ` · TOPIC ${suppliedTopicNumber.toLocaleString()}`
    : "";
  eyebrow.textContent = `${index === 0 ? "PREVIOUS TOPIC" : "EARLIER TOPIC"}${topicLabel}`;
  const question = document.createElement("strong");
  question.textContent = suggestion.question;
  header.append(eyebrow, question);

  const beats = document.createElement("ul");
  beats.className = "history-cues";
  (suggestion.beats || []).forEach((beat) => {
    const item = document.createElement("li");
    const point = document.createElement("span");
    point.textContent = beat.point;
    item.append(point);
    beats.append(item);
  });

  const preamble = document.createElement("p");
  preamble.className = "history-preamble";
  preamble.textContent = suggestion.preamble || "";
  preamble.hidden = !suggestion.preamble;

  round.append(header, preamble, beats);
  const citations = createWebCitationLinks(
    suggestion,
    "history-web-citations"
  );
  if (citations) round.append(citations);
  return round;
}

function scheduleCurrentStageFit() {
  cancelAnimationFrame(currentStageFitFrame);
  const stage = $("#currentStage");
  if (!stage.classList.contains("has-current")) {
    stage.style.removeProperty("--cue-scale");
    stage.dataset.fitScale = "1";
    return;
  }

  stage.style.setProperty("--cue-scale", "1");
  stage.dataset.fitScale = "1";
  let scale = 1;
  let attempts = 0;
  const fit = () => {
    const teleprompter = $(".teleprompter");
    const card = $("#earlyBridge").hidden
      ? $("#answerCard")
      : $("#earlyBridge");
    const teleprompterStyle = getComputedStyle(teleprompter);
    const availableHeight = teleprompter.clientHeight
      - (parseFloat(teleprompterStyle.paddingTop) || 0)
      - (parseFloat(teleprompterStyle.paddingBottom) || 0)
      - 8;
    const contentHeight = card.getBoundingClientRect().bottom
      - stage.getBoundingClientRect().top;
    if (!Number.isFinite(contentHeight) || contentHeight <= availableHeight) return;

    scale = Math.max(0.52, scale * availableHeight / contentHeight * 0.995);
    stage.style.setProperty("--cue-scale", scale.toFixed(3));
    stage.dataset.fitScale = scale.toFixed(3);
    attempts += 1;
    if (attempts < 4 && scale > 0.52) {
      currentStageFitFrame = requestAnimationFrame(fit);
    }
  };
  currentStageFitFrame = requestAnimationFrame(fit);
}

function renderEarlyBridge(bridge) {
  const panel = $("#earlyBridge");
  panel.hidden = !bridge;
  if (!bridge) return;
  $("#earlyBridgeText").textContent = bridge.text;
  $("#earlyBridgeTime").textContent = Number.isFinite(bridge.generationMilliseconds)
    ? `${bridge.generationMilliseconds.toLocaleString()} ms`
    : "";
}

function renderSuggestionStack(assistant) {
  const suggestions = answerHistoryFor(assistant);
  const current = assistant?.suggestion || suggestions[0] || null;
  $("#currentStage").classList.toggle("has-current", Boolean(current));
  state.visibleSuggestions = suggestions;
  state.currentSuggestion = current;
  renderTopicContext(current, suggestions);
  $("#answerStack").hidden = !current;
  if (!current) {
    $("#answerHistory").hidden = true;
    $("#webCitations").hidden = true;
    $("#webCitations").replaceChildren();
    scheduleCurrentStageFit();
    return null;
  }

  $("#answerQuestion").textContent = current.question;
  const preamble = $("#answerPreamble");
  preamble.textContent = current.preamble || "";
  preamble.hidden = !current.preamble;
  const meeting = state.snapshot?.session?.purpose === "meeting";
  $("#answerLead").textContent = meeting ? "Respond from here" : "Speak from here";
  const previousVersion = previousVersionFor(suggestions, current);
  replaceAnswerBeats(
    $("#answerBeats"),
    current.beats,
    previousVersion?.beats || []
  );
  const webCitations = createWebCitationLinks(current, "web-citations");
  $("#webCitations").replaceChildren(...(webCitations?.children || []));
  $("#webCitations").hidden = !webCitations;
  const citationCount = (current.citations || []).length;
  const usesGeneralKnowledge = current.grounding === "generalKnowledge" || citationCount === 0;
  const plausibleRehearsal = current.answerMode === "plausibleRehearsal";
  $("#answerCard").classList.toggle("uses-general-knowledge", usesGeneralKnowledge);
  $("#answerCard").classList.toggle("is-plausible", plausibleRehearsal);
  $("#groundingNotice").hidden = !plausibleRehearsal && !usesGeneralKnowledge;
  if (plausibleRehearsal) {
    const assumptionCount = (current.plausibleAssumptions || []).length;
    $("#groundingNotice strong").textContent = "PLAUSIBLE REHEARSAL · VERIFY";
    $("#groundingNotice small").textContent = assumptionCount
      ? `${assumptionCount} invented premise${assumptionCount === 1 ? "" : "s"} disclosed; replace them with your real example.`
      : "Treat project details and causal claims as a template until verified.";
  } else if (usesGeneralKnowledge) {
    $("#groundingNotice strong").textContent = meeting
      ? "VERIFY BEFORE STATING"
      : "GENERAL GUIDANCE";
    $("#groundingNotice small").textContent = meeting
      ? "The references did not establish a factual answer."
      : "This cue is phrased as an approach, not as personal history.";
  }
  $("#groundingLabel").lastChild.textContent = ` ${groundingText(current)}`;
  $("#generationTime").textContent = generationTimingText(current);
  const citation = current.citations?.[0];
  state.currentCitationPath = citation?.path || "";
  $("#sourceCitationText").textContent = citation ? `${citation.label} · ${citation.path}` : "";
  $("#sourceCitation").hidden = !citation;
  $("#pinButton").classList.toggle("is-active", assistant?.pinnedSuggestionID === current.id);

  const previous = previousEntriesFor(suggestions, current);
  $("#answerHistory").hidden = previous.length === 0;
  $("#answerHistoryCount").textContent = `${previous.length} previous topic${previous.length === 1 ? "" : "s"}`;
  const historyCards = $("#answerHistoryCards");
  historyCards.replaceChildren(...previous.map(createHistoryRound));
  scheduleCurrentStageFit();

  if (state.renderedSuggestionID !== current.id) {
    state.renderedSuggestionID = current.id;
    $(".teleprompter").scrollTop = 0;
    $("#answerCard").animate(
      [{ opacity: 0.45, transform: "translateY(-5px)" }, { opacity: 1, transform: "translateY(0)" }],
      { duration: 260, easing: "ease-out" }
    );
  }
  return current;
}

function renderAssistant(assistant, paused = state.snapshot?.session?.suggestionsPaused) {
  if (state.snapshot?.session?.assistantAvailable === false) {
    $("#currentStage").hidden = true;
    $("#answerHistory").hidden = true;
    $("#pausedState").hidden = true;
    return;
  }
  $("#currentStage").hidden = false;
  renderInferenceStatus();
  const empty = $("#pausedState");
  const listeningStrip = $("#listeningStrip");
  const meeting = state.snapshot?.session?.purpose === "meeting";
  const bridge = assistant?.bridge || null;
  const suggestion = renderSuggestionStack(
    bridge
      ? { ...assistant, suggestion: null, suggestionHistory: [] }
      : assistant
  );
  renderEarlyBridge(bridge);
  const plausibleRehearsal = suggestion?.answerMode === "plausibleRehearsal"
    || state.snapshot?.session?.answerMode === "plausibleRehearsal";
  listeningStrip.hidden = !suggestion;
  listeningStrip.classList.remove("is-updating", "is-plausible");
  listeningStrip.classList.toggle("is-plausible", plausibleRehearsal);
  $("#topicEyebrow").textContent = plausibleRehearsal
    ? "PLAUSIBLE REHEARSAL · VERIFY"
    : "CURRENT TOPIC";
  if (suggestion) {
    $("#questionText").textContent = suggestion.question;
    $("#confidenceLabel").innerHTML = `<i></i> ${suggestion.confidence} confidence`;
  }

  if (bridge) {
    $("#currentStage").classList.add("has-current");
    $("#answerStack").hidden = true;
    $("#answerHistory").hidden = true;
    listeningStrip.hidden = false;
    listeningStrip.classList.add("is-updating", "is-plausible");
    $("#topicEyebrow").textContent = "EARLY BRIDGE · PARTIAL QUESTION";
    $("#questionText").textContent = bridge.sourceText;
    $("#topicContext").hidden = true;
    empty.hidden = true;
    $("#assistantState").textContent = assistant?.phase === "working"
      ? "Early bridge ready; drafting the full cue"
      : "Early bridge ready from partial speech";
    scheduleCurrentStageFit();
    return;
  }

  if (paused) {
    empty.hidden = Boolean(suggestion);
    if (!suggestion) {
      $("#emptyStateSymbol").textContent = "Ⅱ";
      $("#emptyStateTitle").textContent = "Live response outlines paused";
      $("#emptyStateDetail").textContent = "The transcript is still arriving. Resume when you want response cues again.";
    }
    return;
  }

  if (assistant?.phase === "working") {
    listeningStrip.hidden = false;
    listeningStrip.classList.add("is-updating");
    if (suggestion) {
      $("#topicEyebrow").textContent = plausibleRehearsal
        ? "PLAUSIBLE REHEARSAL · NEXT DRAFT"
        : "CURRENT TOPIC · NEXT CUE DRAFTING";
    } else {
      $("#topicEyebrow").textContent = plausibleRehearsal
        ? "PLAUSIBLE REHEARSAL · DRAFTING"
        : "NEXT TOPIC";
      $("#questionText").textContent = `Drafting shorthand beats from the latest ${triggerLabel(assistant.evaluatingTrigger)}…`;
    }
    empty.hidden = true;
    $("#assistantState").textContent = "Drafting an answer outline";
    return;
  }

  if (assistant?.phase === "failed" || assistant?.phase === "unavailable") {
    empty.hidden = Boolean(suggestion);
    if (!suggestion) {
      $("#emptyStateSymbol").textContent = "!";
      $("#emptyStateTitle").textContent = assistant.phase === "unavailable" ? "Assistant setup needed" : "Assistant needs attention";
      $("#emptyStateDetail").textContent = assistant.lastError || "The transcript continues while the assistant recovers.";
    }
    return;
  }

  if (!suggestion) {
    empty.hidden = false;
    const session = state.snapshot?.session;
    const reference = state.snapshot?.reference;
    const checkedWithoutGuidance = ["notAnswerable", "noSuggestion"].includes(
      assistant?.lastEvaluationOutcome
    );
    if (session?.isPreparingSyntheticInterview) {
      $("#emptyStateSymbol").textContent = "AI";
      $("#emptyStateTitle").textContent = `Building the generated ${meeting ? "meeting" : "interview"}`;
      $("#emptyStateDetail").textContent = `The first ${meeting ? "meeting" : "interviewer"} question will appear when the five document-grounded exchanges are ready.`;
    } else if (!session?.isListening) {
      $("#emptyStateSymbol").textContent = "■";
      $("#emptyStateTitle").textContent = `${meeting ? "Meeting" : "Interview"} capture is stopped`;
      $("#emptyStateDetail").textContent = `Start a live ${meeting ? "meeting" : "interview"} or generated replay in the Mac app.`;
    } else {
      const hasLocalReferences = reference?.phase === "ready" && reference?.documentCount > 0;
      $("#emptyStateSymbol").textContent = checkedWithoutGuidance ? "✓" : "AI";
      $("#emptyStateTitle").textContent = checkedWithoutGuidance
        ? `${meeting ? "Meeting" : "Interviewer"} moment checked`
        : `Waiting for the ${meeting ? "other participant" : "interviewer"}`;
      $("#emptyStateDetail").textContent = checkedWithoutGuidance
        ? "The model ran but did not have a sufficiently clear question to outline."
        : hasLocalReferences
          ? `A ${meeting ? "participant" : "interviewer"} pause can start a grounded answer outline before turn finalization.`
          : `${meeting ? "Meeting questions" : "Interviewer pauses"} can produce clearly labeled, cautious response outlines.`;
    }
    return;
  }

  empty.hidden = true;
  if (assistant?.phase === "ready") {
    listeningStrip.hidden = false;
  }
}

function renderSnapshot(snapshot) {
  if (state.snapshot?.streamId !== snapshot.streamId) {
    state.renderedSuggestionID = null;
    state.fallbackTopicNumbers.clear();
    state.nextFallbackTopicNumber = 0;
    state.topicStartedAtByTopicID.clear();
  }
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
      state.snapshot.assistant.evaluatingTrigger = payload.trigger;
      state.snapshot.assistant.evaluationTriggeredAt = payload.triggeredAt;
      state.snapshot.assistant.evaluationStartedAt = payload.startedAt;
      renderAssistant(state.snapshot.assistant);
      break;
    case "assistant.bridge":
      state.snapshot.assistant.bridge = payload;
      renderAssistant(state.snapshot.assistant);
      break;
    case "assistant.suggestion":
      state.snapshot.assistant.phase = "ready";
      state.snapshot.assistant.bridge = null;
      state.snapshot.assistant.suggestion = payload;
      state.snapshot.assistant.suggestionHistory = [
        payload,
        ...(state.snapshot.assistant.suggestionHistory || []).filter((item) => item.id !== payload.id)
      ].slice(0, 4);
      state.snapshot.assistant.lastError = null;
      state.snapshot.assistant.evaluatingSequence = null;
      state.snapshot.assistant.lastEvaluatedSequence = payload.basedOnSequence;
      state.snapshot.assistant.lastEvaluationAt = payload.generatedAt;
      state.snapshot.assistant.lastEvaluationOutcome = payload.inferenceOutcome || "suggestion";
      state.snapshot.assistant.lastEvaluationTrigger = payload.trigger;
      state.snapshot.assistant.lastEvaluationLatencyMilliseconds = payload.totalLatencyMilliseconds;
      state.snapshot.assistant.evaluatingTrigger = null;
      state.snapshot.assistant.evaluationTriggeredAt = null;
      state.snapshot.assistant.evaluationStartedAt = null;
      renderAssistant(state.snapshot.assistant);
      break;
    case "assistant.failed":
      state.snapshot.assistant.phase = payload.phase || "failed";
      state.snapshot.assistant.bridge = null;
      state.snapshot.assistant.lastError = payload.message;
      state.snapshot.assistant.lastEvaluationOutcome = payload.outcome || "failed";
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
    const synthetic = state.snapshot?.session?.source === "syntheticInterview";
    const meeting = state.snapshot?.session?.purpose === "meeting";
    $("#modeRibbon").textContent = synthetic
      ? `GENERATED ${meeting ? "MEETING" : "INTERVIEW"} REPLAY · grounded in references · live response comparison`
      : meeting
        ? "LIVE MEETING · grounded Meeting Assistant · replayable SSE"
        : "LIVE INTERVIEW · host-owned assistant · replayable SSE";
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
  $("#previewControls").hidden = true;
  renderSnapshot(snapshot);
  openEventStream();
}

function renderMockScenario(index) {
  const scenario = mockScenarios[index];
  state.mockGeneration += 1;
  $("#pinButton").classList.remove("is-active");
  const suggestion = {
    id: `mock-answer-${state.mockGeneration}`,
    basedOnSequence: 2_487 + state.mockGeneration,
    question: scenario.question,
    preamble: scenario.preamble,
    beats: scenario.beats,
    citations: scenario.citations || [{ label: "Reference", path: scenario.citation }],
    grounding: scenario.grounding || "localReferences",
    confidence: "high",
    generatedAt: new Date().toISOString(),
    generationMilliseconds: scenario.generationMilliseconds || 640,
    trigger: "partialTranscript",
    totalLatencyMilliseconds: scenario.totalLatencyMilliseconds || 1_440,
    topicID: `mock-topic-${state.mockGeneration}`,
    topicNumber: state.mockGeneration
  };
  state.mockHistory = [suggestion, ...state.mockHistory].slice(0, 4);
  $("#transcriptQuestion").textContent = scenario.question.replaceAll("“", "").replaceAll("”", "");
  $("#partialWords").textContent = scenario.candidateStart;
  renderMockHistory();
}

function renderMockHistory() {
  renderAssistant({
    phase: "ready",
    suggestion: state.mockHistory[0] || null,
    suggestionHistory: state.mockHistory,
    pinnedSuggestionID: $("#pinButton").classList.contains("is-active")
      ? state.mockHistory[0]?.id
      : null
  }, false);
}

function enterMockMode() {
  state.mode = "mock";
  state.mockHistory = [];
  state.mockGeneration = 0;
  $("#modeRibbon").textContent = "STANDALONE PREVIEW · simulated events (start the Swift app for live mode)";
  setConnectionStatus("disconnected", "Not connected", "PREVIEW");
  $("#previewControls").hidden = false;
  renderMockScenario(0);
}

function testReconnect() {
  if (state.mode !== "live") {
    setConnectionStatus("reconnecting", "Simulating retry · 1.0 s");
    showRecovery("Connection interrupted", "Simulating host-side capture continuing…");
    setTimeout(() => {
      setConnectionStatus("disconnected", "Not connected", "PREVIEW");
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
  function openCitation(path) {
    if (!path) {
      showToast("Citation metadata unavailable");
      return;
    }
    try {
      const url = new URL(path);
      if (url.protocol === "http:" || url.protocol === "https:") {
        window.open(url.href, "_blank", "noopener,noreferrer");
        return;
      }
    } catch {}
    showToast(path);
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
  $("#simulateDropButton").addEventListener("click", testReconnect);
  $("#popoverDropButton").addEventListener("click", testReconnect);

  $("#assistantToggle").addEventListener("change", async (event) => {
    const active = event.target.checked;
    try {
      const result = await sendCommand(active ? "resumeSuggestions" : "pauseSuggestions");
      showToast(result.message);
      if (state.mode === "mock") {
        if (active) renderMockHistory();
        else renderAssistant({
          phase: "ready",
          suggestion: state.mockHistory[0] || null,
          suggestionHistory: state.mockHistory
        }, true);
      }
    } catch (error) {
      event.target.checked = !active;
      showToast(error.message);
    }
  });

  $("#nextMomentButton").addEventListener("click", () => {
    state.mockIndex = (state.mockIndex + 1) % mockScenarios.length;
    renderMockScenario(state.mockIndex);
    showToast("New simulated answer outline");
  });
  $("#previewWebSearchButton").addEventListener("click", () => {
    const index = mockScenarios.findIndex((scenario) => scenario.isWebSearchPreview);
    if (index < 0) return;
    state.mockIndex = index;
    renderMockScenario(index);
    showToast("Simulated web-search result · no API call");
  });
  document.addEventListener("keydown", (event) => {
    if (state.mode === "mock" && event.key.toLowerCase() === "n" && !event.metaKey && !event.ctrlKey && !event.altKey) {
      $("#nextMomentButton").click();
    }
    if (state.mode === "mock" && event.key.toLowerCase() === "w" && !event.metaKey && !event.ctrlKey && !event.altKey) {
      $("#previewWebSearchButton").click();
    }
  });

  $("#pinButton").addEventListener("click", async (event) => {
    const button = event.currentTarget;
    const isPinned = button.classList.contains("is-active");
    const suggestionID = state.currentSuggestion?.id;
    try {
      const result = await sendCommand(isPinned ? "unpinSuggestion" : "pinSuggestion", suggestionID);
      if (result.applied) button.classList.toggle("is-active", !isPinned);
      showToast(result.message);
    } catch (error) {
      showToast(error.message);
    }
  });

  $("#dismissButton").addEventListener("click", async () => {
    const suggestionID = state.currentSuggestion?.id;
    try {
      const result = await sendCommand("dismissSuggestion", suggestionID);
      if (state.mode === "mock" && result.applied) {
        state.mockHistory = state.mockHistory.filter((item) => item.id !== suggestionID);
        renderMockHistory();
      }
      showToast(result.message);
    } catch (error) {
      showToast(error.message);
    }
  });

  async function copySuggestion(suggestion) {
    if (!suggestion) return;
    const answerParts = [outlineText(suggestion)];
    if (suggestion.grounding === "generalKnowledge" || !(suggestion.citations || []).length) {
      answerParts.unshift("NO LOCAL SUPPORTING MATERIAL — Approach-oriented outline; no unverified personal experience claimed.");
    }
    try {
      await navigator.clipboard.writeText(answerParts.join("\n\n"));
      showToast("Copied answer outline");
    } catch {
      showToast("Copy is unavailable in this browser");
    }
  }

  $("#copyButton").addEventListener("click", async () => {
    await copySuggestion(state.currentSuggestion);
  });
  $("#answerHistory").addEventListener("click", async (event) => {
    const copyButton = event.target.closest("[data-copy-suggestion-id]");
    if (copyButton) {
      const suggestion = state.visibleSuggestions.find(
        (item) => item.id === copyButton.dataset.copySuggestionId
      );
      await copySuggestion(suggestion);
      return;
    }
    const citationButton = event.target.closest("[data-citation-path]");
    if (citationButton) {
      openCitation(citationButton.dataset.citationPath);
    }
  });
  $("#webCitations").addEventListener("click", (event) => {
    const citationButton = event.target.closest("[data-citation-path]");
    if (citationButton) openCitation(citationButton.dataset.citationPath);
  });
  $("#sourceCitation").addEventListener("click", () => {
    openCitation(state.currentCitationPath);
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
  updateTopicElapsedTime();
}

async function initialize() {
  bindControls();
  window.addEventListener("resize", scheduleCurrentStageFit);
  setConnectionStatus("reconnecting", "Finding PermanentUnderclass on this Mac", "CONNECTING");
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
