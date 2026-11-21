const formEl = document.getElementById("noteForm");
const inputEl = document.getElementById("noteInput");
const statusEl = document.getElementById("status");
const notesListEl = document.getElementById("notesList");

function renderNotes(notes) {
  notesListEl.textContent = "";
  for (const note of notes) {
    const li = document.createElement("li");
    li.textContent = note.text;
    notesListEl.appendChild(li);
  }
  statusEl.textContent = `${notes.length} notes`;
}

async function addNote(event) {
  event.preventDefault();
  const text = inputEl.value.trim();
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
