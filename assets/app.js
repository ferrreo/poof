(() => {
  "use strict";

  document.documentElement.classList.add("js");

  const kindSelect = document.querySelector("[data-kind-select]");
  const bugFields = document.querySelector("[data-bug-fields]");
  if (kindSelect && bugFields) {
    const updateBugFields = () => {
      const isBug = kindSelect.value === "bug";
      bugFields.classList.toggle("visible", isBug);
      for (const field of bugFields.querySelectorAll(
        '[name="reproduction_steps"], [name="actual_behavior"]',
      )) {
        field.required = isBug;
      }
    };
    kindSelect.addEventListener("change", updateBugFields);
    updateBugFields();
  }

  for (const form of document.querySelectorAll("[data-confirm]")) {
    form.addEventListener("submit", (event) => {
      const message = form.getAttribute("data-confirm");
      if (message && !window.confirm(message)) event.preventDefault();
    });
  }

  for (const field of document.querySelectorAll("[data-count-target]")) {
    const target = document.getElementById(field.dataset.countTarget);
    if (!target) continue;

    const update = () => {
      target.textContent = String(field.value.length);
    };
    field.addEventListener("input", update);
    update();
  }

  const csrfInput = () =>
    document.querySelector('input[name="_csrf"]') ||
    document.querySelector('input[type="hidden"][name="_csrf"]');

  const statusFor = (fileInput) => {
    const trigger = fileInput.closest(".upload-trigger");
    const sibling = trigger && trigger.nextElementSibling;
    if (sibling && sibling.matches("[data-upload-status]")) return sibling;
    const wrap = fileInput.closest(".upload-field, form, .stacked-form, .comment-form");
    return wrap ? wrap.querySelector("[data-upload-status]") : null;
  };

  const setStatus = (fileInput, message, isError) => {
    const status = statusFor(fileInput);
    if (!status) return;
    if (!message) {
      status.hidden = true;
      status.textContent = "";
      return;
    }
    status.hidden = false;
    status.textContent = message;
    status.classList.toggle("upload-status-error", Boolean(isError));
  };

  const findUrlField = (fileInput) => {
    const wrap = fileInput.closest(".upload-field");
    if (wrap) {
      return (
        wrap.querySelector('input[type="url"]') ||
        wrap.querySelector('input[name="evidence_url"], input[name="logo_url"]')
      );
    }
    const form = fileInput.closest("form");
    return form
      ? form.querySelector('input[name="evidence_url"], input[name="logo_url"]')
      : null;
  };

  const findMarkdownField = (fileInput) => {
    const form = fileInput.closest("form");
    if (!form) return null;
    return (
      form.querySelector("textarea[name='body']") ||
      form.querySelector("textarea")
    );
  };

  const insertMarkdownImage = (textarea, url, filename) => {
    const alt = (filename || "image").replace(/\.[^.]+$/, "") || "image";
    const snippet = `![${alt}](${url})`;
    const start = textarea.selectionStart ?? textarea.value.length;
    const end = textarea.selectionEnd ?? start;
    const before = textarea.value.slice(0, start);
    const after = textarea.value.slice(end);
    const needsPad =
      before.length > 0 && !/\s$/.test(before) ? "\n\n" : before.length > 0 ? "" : "";
    textarea.value = `${before}${needsPad}${snippet}${after}`;
    const cursor = (before + needsPad + snippet).length;
    textarea.focus();
    textarea.setSelectionRange(cursor, cursor);
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  };

  const uploadImage = async (fileInput) => {
    const file = fileInput.files && fileInput.files[0];
    if (!file) return;

    const csrf = csrfInput();
    if (!csrf || !csrf.value) {
      setStatus(fileInput, "Sign in to upload images.", true);
      fileInput.value = "";
      return;
    }

    const mode = fileInput.dataset.imageUpload || "url";
    setStatus(fileInput, "Uploading…");
    fileInput.disabled = true;

    try {
      const body = new FormData();
      body.append("_csrf", csrf.value);
      body.append("file", file, file.name);

      const response = await fetch("/uploads", {
        method: "POST",
        body,
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });

      if (!response.ok) {
        const text = await response.text();
        throw new Error(text || `Upload failed (${response.status})`);
      }

      const payload = await response.json();
      if (!payload || typeof payload.url !== "string") {
        throw new Error("Unexpected upload response.");
      }

      if (mode === "markdown") {
        const textarea = findMarkdownField(fileInput);
        if (!textarea) throw new Error("No Markdown field found.");
        insertMarkdownImage(textarea, payload.url, file.name);
      } else {
        const urlField = findUrlField(fileInput);
        if (!urlField) throw new Error("No URL field found.");
        urlField.value = payload.url;
        urlField.dispatchEvent(new Event("input", { bubbles: true }));
      }
      setStatus(fileInput, "Image ready.");
    } catch (error) {
      const message =
        error && typeof error.message === "string"
          ? error.message.slice(0, 160)
          : "Upload failed.";
      setStatus(fileInput, message, true);
    } finally {
      fileInput.disabled = false;
      fileInput.value = "";
    }
  };

  for (const fileInput of document.querySelectorAll("[data-image-upload]")) {
    fileInput.addEventListener("change", () => {
      void uploadImage(fileInput);
    });
  }
})();
