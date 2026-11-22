import test from "node:test"
import assert from "node:assert/strict"
import { cleanNoteText, formatStatus } from "./public/notes_util.js";

test("cleanNoteText trim surrounding whitespace", () => {
  assert.equal(cleanNoteText("  buy milk  "), "buy milk");
  assert.equal(cleanNoteText("   "), "");
})

test("formatStatus handles singular and plural", () => {
  assert.equal(formatStatus(0), "0 notes");
  assert.equal(formatStatus(1), "1 note");
  assert.equal(formatStatus(3), "3 notes");
})
