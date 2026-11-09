"use strict";
// Ad-hoc signs the Mac app after packaging. Without an Apple Developer ID, electron-builder skips signing,
// and an Apple Silicon Mac then reports the downloaded app as "damaged" (the Electron binary's own
// signature no longer matches the packaged app). An ad-hoc signature fixes that; the first open still
// needs right-click > Open (or System Settings > Privacy & Security > Open Anyway) until the app is
// signed and notarised with a Developer ID (DEPLOY.md, "The Mac app").
const { execFileSync } = require("node:child_process");
const path = require("node:path");

exports.default = async function afterPack(context) {
  if (context.electronPlatformName !== "darwin") return;
  if (context.packager.platformSpecificBuildOptions.identity) return; // a real identity signs instead
  const app = path.join(context.appOutDir, `${context.packager.appInfo.productFilename}.app`);
  execFileSync("codesign", ["--force", "--deep", "--sign", "-", app], { stdio: "inherit" });
  execFileSync("codesign", ["--verify", "--deep", "--strict", app], { stdio: "inherit" });
  console.log(`  ad-hoc signed ${app}`);
};
