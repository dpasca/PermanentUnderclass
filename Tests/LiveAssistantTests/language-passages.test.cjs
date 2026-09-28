const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");
const { runInNewContext } = require("node:vm");
const { test } = require("node:test");

// Exercise the production, DOM-independent projection without launching an
// extra browser or evaluating the companion's network/bootstrap code.
const app = readFileSync(resolve(__dirname, "../../Prototypes/LiveAssistant/app.js"), "utf8");
const start = app.indexOf("function preservesCompletedLanguagePassages(");
const end = app.indexOf("function renderLanguageConversation(", start);
assert.ok(start >= 0 && end > start);
const project = runInNewContext(`${app.slice(start, end)}; languagePassagesForTurn`);
const preserves = runInNewContext(`${app.slice(start, end)}; preservesCompletedLanguagePassages`);
const completed = { source: "今日は税金の話です。", translation: "Today we're discussing taxes.", isComplete: true };
const draft = { source: "次に", translation: "Next…", isComplete: false };
const result = (passages) => ({ question: passages.map(p => p.source).join(""),
  languageAssistance: { passages, translation: passages.map(p => p.translation).join("\n") } });
const turn = (text) => ({ text, partial: true, speaker: "other" });

test("late translations finish the draft without rewriting completed history", () => {
  const before = {passages: [completed, draft]};
  assert.equal(preserves(before, {passages: [completed, {...draft, source:'次に確認します。',isComplete:true}]}), true);
  assert.equal(preserves(before, {passages: [{...completed,translation:'Rewritten'}]}), false);
  assert.equal(preserves(before, {passages: []}), false);
});

test("appended words change only the live draft and never mutate the snapshot", () => {
  const input = result([completed, draft]);
  const before = JSON.stringify(input);
  const output = project(turn(completed.source + "次に領収書を"), input);
  assert.equal(output.length, 2);
  assert.equal(output[0].translation, completed.translation);
  assert.equal(output[1].source, "次に領収書を");
  assert.equal(output[1].pending, true);
  assert.equal(JSON.stringify(input), before);
});

test("a revised ASR draft never duplicates the preceding Japanese", () => {
  const output = project(turn(completed.source + "続いて領収書を"), result([completed, draft]));
  assert.equal(output.length, 2);
  assert.equal(output[1].source, "続いて領収書を");
  assert.equal(output.map(p => p.source).join(""), completed.source + "続いて領収書を");
  assert.equal(output[0].translation, completed.translation);
});

test("new speech after a completed passage creates one separate pending row", () => {
  const output = project(turn(completed.source + "そして"), result([completed]));
  assert.equal(output.length, 2);
  assert.equal(output[0].isComplete, true);
  assert.equal(output[1].translation, "");
  assert.equal(output[1].source, "そして");
});

test("late punctuation stays on the live phrase until the next model-selected passage", () => {
  for (const [source, ending, translation] of [
    ["今日は晴れです", "。", "It's sunny today."],
    ["It is sunny today", ".", "It is sunny today."],
    ["「今日は晴れです", "。」", "“It's sunny today.”"]
  ]) {
    const live = {source, translation, isComplete: false};
    const input = result([completed, live]);
    const before = JSON.stringify(input);
    const punctuated = project(turn(completed.source + source + ending), input);
    assert.equal(punctuated.length, 2);
    assert.equal(punctuated[0].source, completed.source);
    assert.equal(punctuated[1].source, source + ending);
    assert.equal(punctuated[1].translation, translation);
    assert.equal(JSON.stringify(input), before);

    const finished = {...live, source: source + ending, isComplete: true};
    const next = " 次の話題は";
    const continued = project(turn(completed.source + source + ending + next), result([completed, finished]));
    assert.equal(continued.length, 3);
    assert.equal(continued[1].source, source + ending);
    assert.equal(continued[2].source, next);
    assert.equal(continued.map(p => p.source).join(""), completed.source + source + ending + next);
  }
});

test("corrections keep the old source/translation pair until its replacement arrives", () => {
  const wrong = {source: "五万円です。", translation: "It's 50,000 yen.", isComplete: true};
  const output = project(turn(completed.source + "十五万円です。"), result([completed, wrong]));
  assert.equal(output.length, 2);
  assert.equal(output[1].source, wrong.source);
  assert.equal(output[1].translation, wrong.translation);
  assert.equal(output[0].correctedSource, completed.source + "十五万円です。");
});

test("stopping preserves the live breakdown even when the final source is wholly revised", () => {
  const input = result([completed, draft]);
  const output = project({text: "A completely revised final transcript", partial: false}, input, true);
  assert.equal(output.length, 2);
  assert.equal(output[0].source, completed.source);
  assert.equal(output[1].translation, draft.translation);
});

test("legacy snapshots, untranslated speech and both speakers remain readable", () => {
  const legacy = project(turn("はい。次に"), {question: "はい。", languageAssistance: {translation: "Yes."}});
  assert.equal(legacy.map(p => p.source).join(""), "はい。次に");
  assert.equal(legacy[0].translation, "Yes.");
  for (const speaker of ["you", "other"]) {
    const output = project({text: "はい。", speaker, partial: false}, null);
    assert.equal(output.length, 1);
    assert.equal(output[0].source, "はい。");
  }
  assert.equal(project(turn(""), null).length, 0);
});

test("a long podcast keeps all completed pairs when the current phrase is revised", () => {
  const passages = Array.from({length: 100}, (_, index) => ({
    source: `項目${index}です。`, translation: `Item ${index}.`, isComplete: true
  }));
  const prefix = passages.map(p => p.source).join("");
  const input = result([...passages, draft]);
  for (let index = 0; index < 100; ++index) {
    const output = project(turn(prefix + `修正中${index}`), input);
    assert.equal(output.length, 101);
    assert.equal(output[100].source, `修正中${index}`);
    assert.equal(output[99].translation, passages[99].translation);
  }
});
