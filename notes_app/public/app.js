import { cleanNoteText, formatStatus } from "./notes_util.js";

const formEl = document.getElementById("noteForm");
const inputEl = document.getElementById("noteInput");
const statusEl = document.getElementById("status");
const notesListEl = document.getElementById("notesList");

function renderNotes(notes) {
  notesListEl.textContent = "";
  for (const note of notes) {
    const li = document.createElement("li");
    const span = document.createElement("span");
    span.textContent = note.text;
    const btn = document.createElement("button");
    btn.textContent = "Delete";
    btn.className = "delete-btn";
    btn.addEventListener("click", () => deleteNote(note.id));
    li.appendChild(span);
    li.appendChild(btn);
    notesListEl.appendChild(li);
  }
  statusEl.textContent = formatStatus(notes.length);
}

async function addNote(event) {
  event.preventDefault();
  const text = cleanNoteText(inputEl.value);
  if (!text) {
    return;
  }
  try {
    const res = await fetch("/api/notes", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text })
    });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }
    inputEl.value = "";
    await loadNotes();
  } catch(err) {
    statusEl.textContent = `Error adding note: ${err.message}`;
  }
}

async function deleteNote(id) {
  try {
    const res = await fetch(`/api/notes/${id}`, { method: "DELETE" });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }
    await loadNotes();
  } catch(err) {
    statusEl.textContent = `Error deleting note: ${err.message}`;
  }
}

formEl.addEventListener("submit", addNote);

async function loadNotes() {
  try {
    const res = await fetch("/api/notes");
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }
    const notes = await res.json();
    renderNotes(notes);
  } catch(err) {
    statusEl.textContent = `Error loading notes: ${err.message}`;
  }
}

loadNotes();
