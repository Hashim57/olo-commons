"use strict";
(() => {
  document.getElementById("app").append(P.el("h1", {}, "Join POL Net"), P.el("p", { class: "lead" }, "The join window is open. Finish the check there."));
  window.polnet.join();
})();
