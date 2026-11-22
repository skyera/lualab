import { cleanNoteText, formatStatus } from "./notes_util.js";
import { createRandomFlowerBlob } from "./flower.js";

const themeBtnEl = document.getElementById("themeBtn");
const formEl = document.getElementById("noteForm");
const inputEl = document.getElementById("noteInput");
const statusEl = document.getElementById("status");
const notesListEl = document.getElementById("notesList");
const photoInputEl = document.getElementById("photoInput");
const photoPreviewEl = document.getElementById("photoPreview");
const photoBtnEl = document.getElementById("photoBtn");
const flowerBtnEl = document.getElementById("flowerBtn");
let pendingImageUrl = null;

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
    const editBtn = document.createElement("button");
    editBtn.textContent = "Edit";
    editBtn.className = "edit-btn";
    editBtn.addEventListener("click", () => editNote(note));
    if (note.image) {
      const img = document.createElement("img");
      img.src = note.image;
      img.alt = "";
      img.className = "note-thumb";
      li.appendChild(img);
    }
    li.appendChild(span);
    li.appendChild(editBtn);
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
      body: JSON.stringify({ text, image:pendingImageUrl })
    });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }
    inputEl.value = "";
    pendingImageUrl = null;
    photoPreviewEl.hidden = true;
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

async function editNote(note) {
  const raw = window.prompt("Edit note:", note.text);
  if (raw === null) {
    return;
  }
  const text = cleanNoteText(raw);
  if (!text || text === note.text) {
    return;
  }
  try {
    const res = await fetch(`/api/notes/${note.id}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text })
    });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }
    await loadNotes();
  } catch(err) {
    statusEl.textContent = `Error editing note: ${err.message}`;
  }
}

flowerBtnEl.addEventListener("click", async () => {
  const blob = await createRandomFlowerBlob();
  await uploadBlob(blob);
})
photoBtnEl.addEventListener("click", () => photoInputEl.click());
photoInputEl.addEventListener("change", async () => {
  if (photoInputEl.files[0]) {
    await uploadBlob(photoInputEl.files[0]);
    photoInputEl.value = "";
  }
})

formEl.addEventListener("submit", addNote);

async function uploadBlob(blob) {
  try {
    const res = await fetch("/api/upload", { method: "POST", body: blob });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }
    const data = await res.json();
    pendingImageUrl = data.url;
    photoPreviewEl.src = data.url;
    photoPreviewEl.hidden = false;
  } catch(err) {
    statusEl.textContent = `Error uploading image: ${err.message}`;
  }
}

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

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  themeBtnEl.textContent = theme === "dark" ? "Light" : "Dark";
}

function toggleTheme() {
  const current = document.documentElement.dataset.theme;
  const next = current === "dark" ? "light" : "dark";
  applyTheme(next);
  try {
    localStorage.setItem("notes.theme", next);
  } catch(err) {
    console.warn("Cannot save theme:", err);
  }
}

themeBtnEl.addEventListener("click", toggleTheme);
try {
  applyTheme(localStorage.getItem("notes.theme") || "light");
} catch(err) {
  applyTheme("light");
}

loadNotes();
