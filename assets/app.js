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
})();
