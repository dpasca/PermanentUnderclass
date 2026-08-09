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
    candidateStart: "Yeah—the clearest one is probably our checkout path...",
    beats: [
      { label: "What I saw", point: "I inherited a checkout path that had become noticeably slow." },
      { label: "What I tried", point: "I profiled it and found repeated inventory lookups." },
      { label: "Check", point: "I replayed real traffic and watched p95, not just averages." },
      { label: "Afterward", point: "I added a latency alert so the regression could not return quietly." }
    ],
    citation: "Projects/Checkout.md"
  },
  {
    question: "“What did you learn when that launch did not go to plan?”",
    candidateStart: "Honestly, that first rollout was messier than I expected...",
    beats: [
      { label: "What broke", point: "I had planned too much around the happy path." },
      { label: "First move", point: "I paused the rollout and added a compatibility layer." },
      { label: "Messy bit", point: "I got both teams debugging from the same timeline." },
      { label: "Now", point: "I now rehearse rollback and mixed-version cases before launch." }
    ],
    citation: "Projects/Rollout-retro.md"
  },
  {
    question: "“How do you decide when a low-latency system is ready to ship?”",
    candidateStart: "I start with what delay a person can actually feel...",
    beats: [
      { label: "Start", point: "I start by choosing a delay people can actually notice." },
      { label: "Break it down", point: "I measure capture, model, and display latency separately." },
      { label: "Try bad cases", point: "I replay awkward pauses and broken connections." },
      { label: "Good enough", point: "I ship when it feels fast without firing at the wrong time." }
    ],
    citation: "Projects/Audio-assistant.md"
  },
  {
    question: "“What tradeoff did you make to keep the assistant useful?”",
    candidateStart: "The awkward part was answering early without jumping in too soon...",
    beats: [
      { label: "The tension", point: "I was balancing an early answer against a cleaner transcript." },
      { label: "What I chose", point: "I started generation after a stable 800-millisecond pause." },
      { label: "Fallback", point: "I ran it again when the final turn arrived." },
      { label: "Still checking", point: "I still measured whether early cues were useful, not merely fast." }
    ],
    citation: "Architecture/Latency-harness.md"
  },
  {
    question: "“A CUDA kernel shows high occupancy but still runs slowly. What would you look at next?”",
    candidateStart: "I would not trust occupancy by itself; I would open Nsight Compute first...",
    beats: [
      { label: "First thought", point: "I would not treat high occupancy as proof of useful work." },
      { label: "Memory", point: "I would check coalescing, cache misses, and DRAM throughput." },
      { label: "Warp stalls", point: "I would use Nsight Compute to see why warps were stalled." },
      { label: "Then code", point: "I would inspect divergence, register spills, and expensive instructions." }
    ],
    citation: "Notes/CUDA-performance.md"
  },
  {
    question: "“Why might a tiled CUDA matrix multiply get slower when you increase the tile size?”",
    candidateStart: "My first guess is that the larger tile pushed resource use too far...",
    beats: [
      { label: "Likely cost", point: "I would first suspect the larger tile pushed resource use too far." },
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
    beats: [
      { label: "Current release", point: "I’d confirm the production release in NVIDIA’s current toolkit notes." },
      { label: "Profiler change", point: "I’d pull one documented profiling change from that same release." },
      { label: "Version check", point: "I’d separate toolkit, driver, and Nsight versions before answering." },
      { label: "Source", point: "I’d link the official release notes so the answer stays checkable." }
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
  topicStartedAtBySuggestionID: new Map(),
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
  $("#connectionLabel").textContent = label;
  chip.setAttribute("aria-label", label);
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
  const checkCount = snapshot?.usage?.assistantGenerations ?? 0;
  const hasLocalReferences = reference?.phase === "ready" && reference?.documentCount > 0;
  const meeting = session?.purpose === "meeting";
  const assistantName = meeting ? "Meeting Assistant" : "Answer Mirror";
  const otherSpeaker = meeting ? "other participant" : "interviewer";

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
      hasLocalReferences ? "working" : "general",
      hasLocalReferences ? "INFERENCE RUNNING NOW" : "INFERENCE RUNNING · GENERAL KNOWLEDGE",
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
    const usesGeneralKnowledge = assistant.suggestion.grounding === "generalKnowledge"
      || !(assistant.suggestion.citations || []).length;
    setInferenceStatus(
      usesGeneralKnowledge ? "general" : "active",
      usesGeneralKnowledge
        ? "INFERENCE ACTIVE · GENERAL KNOWLEDGE"
        : "INFERENCE ACTIVE · LOCALLY GROUNDED",
      usesGeneralKnowledge
        ? `${assistantName} outline ready without local support`
        : "A locally grounded answer outline is ready",
      usesGeneralKnowledge
        ? meeting
          ? "The outline marks what should be verified and avoids invented project facts."
          : "The outline is approach-oriented and avoids unverified personal claims."
        : `Based on event #${assistant.suggestion.basedOnSequence.toLocaleString()} · compare it with your transcript on the right.`,
      checkCount
    );
    return;
  }

  if (assistant?.lastEvaluationOutcome === "noSuggestion") {
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

function renderTranscript(transcript) {
  const container = $("#transcriptScroll");
  container.replaceChildren();
  const turns = transcript?.turns || [];
  const partials = transcript?.partials || [];
  if (!turns.length && !partials.length) {
    const empty = document.createElement("article");
    empty.className = "turn";
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

function fallbackTopicNumber(suggestion, suggestions) {
  [...suggestions].reverse().forEach((item) => {
    if (!item?.id || state.fallbackTopicNumbers.has(item.id)) return;
    state.nextFallbackTopicNumber += 1;
    state.fallbackTopicNumbers.set(item.id, state.nextFallbackTopicNumber);
  });
  if (!state.fallbackTopicNumbers.has(suggestion.id)) {
    state.nextFallbackTopicNumber += 1;
    state.fallbackTopicNumbers.set(suggestion.id, state.nextFallbackTopicNumber);
  }
  return state.fallbackTopicNumbers.get(suggestion.id);
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

  if (!state.topicStartedAtBySuggestionID.has(suggestion.id)) {
    const generatedAt = new Date(suggestion.generatedAt).getTime();
    state.topicStartedAtBySuggestionID.set(
      suggestion.id,
      Number.isFinite(generatedAt) ? generatedAt : Date.now()
    );
  }
  updateTopicElapsedTime();
}

function updateTopicElapsedTime() {
  const suggestion = state.currentSuggestion;
  if (!suggestion) return;
  const startedAt = state.topicStartedAtBySuggestionID.get(suggestion.id);
  if (!Number.isFinite(startedAt)) return;
  const elapsed = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
  const topicNumber = $("#topicNumber").textContent;
  $("#topicElapsed").textContent = formatElapsedClock(elapsed);
  $("#topicContext").setAttribute(
    "aria-label",
    `Topic ${topicNumber}, elapsed ${formatDuration(elapsed)}`
  );
}

function replaceAnswerBeats(container, beats) {
  container.replaceChildren();
  (beats || []).forEach((beat) => {
    const item = document.createElement("li");
    const label = document.createElement("strong");
    label.textContent = beat.label;
    const point = document.createElement("span");
    point.textContent = beat.point;
    item.append(label, point);
    container.append(item);
  });
}

function previousRoundsFor(suggestions, current) {
  const currentQuestion = current?.question?.trim().toLocaleLowerCase() || "";
  const seen = new Set(currentQuestion ? [currentQuestion] : []);
  const previous = [];

  suggestions.forEach((suggestion) => {
    if (!suggestion || suggestion.id === current?.id) return;
    const question = suggestion.question?.trim();
    const key = question?.toLocaleLowerCase();
    if (!question || seen.has(key)) return;
    seen.add(key);
    previous.push(suggestion);
  });
  return previous.slice(0, 3);
}

function outlineText(suggestion) {
  if (!suggestion) return "";
  return [
    suggestion.question,
    ...(suggestion.beats || []).map((beat) => beat.point)
  ].join("\n");
}

function groundingText(suggestion) {
  const citationCount = (suggestion.citations || []).length;
  const usesGeneralKnowledge = suggestion.grounding === "generalKnowledge" || citationCount === 0;
  const usesWebSearch = suggestion.grounding === "webSearch" && citationCount > 0;
  const meeting = state.snapshot?.session?.purpose === "meeting";
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
  eyebrow.textContent = index === 0 ? "PREVIOUS ROUND" : `${index + 1} ROUNDS BACK`;
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

  round.append(header, beats);
  const citations = createWebCitationLinks(
    suggestion,
    "history-web-citations"
  );
  if (citations) round.append(citations);
  return round;
}

function renderSuggestionStack(assistant) {
  const suggestions = answerHistoryFor(assistant);
  const current = assistant?.suggestion || suggestions[0] || null;
  state.visibleSuggestions = suggestions;
  state.currentSuggestion = current;
  renderTopicContext(current, suggestions);
  $("#answerStack").hidden = !current;
  if (!current) {
    $("#answerHistory").hidden = true;
    $("#webCitations").hidden = true;
    $("#webCitations").replaceChildren();
    return null;
  }

  $("#answerQuestion").textContent = current.question;
  const meeting = state.snapshot?.session?.purpose === "meeting";
  $("#answerLead").textContent = meeting ? "Respond from here" : "Speak from here";
  replaceAnswerBeats($("#answerBeats"), current.beats);
  const webCitations = createWebCitationLinks(current, "web-citations");
  $("#webCitations").replaceChildren(...(webCitations?.children || []));
  $("#webCitations").hidden = !webCitations;
  const citationCount = (current.citations || []).length;
  const usesGeneralKnowledge = current.grounding === "generalKnowledge" || citationCount === 0;
  $("#answerCard").classList.toggle("uses-general-knowledge", usesGeneralKnowledge);
  $("#groundingNotice").hidden = !usesGeneralKnowledge;
  if (usesGeneralKnowledge) {
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

  const previous = previousRoundsFor(suggestions, current);
  $("#answerHistory").hidden = previous.length === 0;
  $("#answerHistoryCount").textContent = `${previous.length} previous round${previous.length === 1 ? "" : "s"}`;
  const historyCards = $("#answerHistoryCards");
  historyCards.replaceChildren(...previous.map(createHistoryRound));

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
  renderInferenceStatus();
  const empty = $("#pausedState");
  const listeningStrip = $("#listeningStrip");
  const meeting = state.snapshot?.session?.purpose === "meeting";
  const suggestion = renderSuggestionStack(assistant);
  listeningStrip.hidden = !suggestion;
  listeningStrip.classList.remove("is-updating");
  $("#topicEyebrow").textContent = "CURRENT TOPIC";
  if (suggestion) {
    $("#questionText").textContent = suggestion.question;
    $("#confidenceLabel").innerHTML = `<i></i> ${suggestion.confidence} confidence`;
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
      $("#topicEyebrow").textContent = "CURRENT TOPIC · NEXT CUE DRAFTING";
    } else {
      $("#topicEyebrow").textContent = "NEXT TOPIC";
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
    const checkedWithoutGuidance = assistant?.lastEvaluationOutcome === "noSuggestion";
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
    state.topicStartedAtBySuggestionID.clear();
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
    case "assistant.suggestion":
      state.snapshot.assistant.phase = "ready";
      state.snapshot.assistant.suggestion = payload;
      state.snapshot.assistant.suggestionHistory = [
        payload,
        ...(state.snapshot.assistant.suggestionHistory || []).filter((item) => item.id !== payload.id)
      ].slice(0, 4);
      state.snapshot.assistant.lastError = null;
      state.snapshot.assistant.evaluatingSequence = null;
      state.snapshot.assistant.lastEvaluatedSequence = payload.basedOnSequence;
      state.snapshot.assistant.lastEvaluationAt = payload.generatedAt;
      state.snapshot.assistant.lastEvaluationOutcome = "suggestion";
      state.snapshot.assistant.lastEvaluationTrigger = payload.trigger;
      state.snapshot.assistant.lastEvaluationLatencyMilliseconds = payload.totalLatencyMilliseconds;
      state.snapshot.assistant.evaluatingTrigger = null;
      state.snapshot.assistant.evaluationTriggeredAt = null;
      state.snapshot.assistant.evaluationStartedAt = null;
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
    beats: scenario.beats,
    citations: scenario.citations || [{ label: "Reference", path: scenario.citation }],
    grounding: scenario.grounding || "localReferences",
    confidence: "high",
    generatedAt: new Date().toISOString(),
    generationMilliseconds: scenario.generationMilliseconds || 640,
    trigger: "partialTranscript",
    totalLatencyMilliseconds: scenario.totalLatencyMilliseconds || 1_440,
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
