import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export default function droidPeekQmllint(pi: ExtensionAPI): void {
  pi.setLabel("Droid Peek QML lint");

  pi.on("turn_end", async (_event, ctx) => {
    const result = await pi.exec(
      "bash",
      ["scripts/dev/lint-qml.sh", "--fix"],
      { cwd: ctx.cwd },
    );
    if (result.killed)
      return;

    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
    if (result.code === 0 && output.length === 0) {
      ctx.ui.setStatus("qmllint", "");
      return;
    }

    const summary = output.split("\n").slice(0, 12).join("\n");
    ctx.ui.setStatus(
      "qmllint",
      result.code === 0 ? "qmllint warnings" : "qmllint failed",
    );
    if (ctx.hasUI && summary.length > 0)
      ctx.ui.notify(summary, result.code === 0 ? "warning" : "error");
  });
}
