import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

type LintJob = {
  script: string;
  key: string;
  warned: string;
  failed: string;
};

const jobs: LintJob[] = [
  {
    script: "scripts/dev/lint-qml.sh",
    key: "qmllint",
    warned: "qmllint warnings",
    failed: "qmllint failed",
  },
  {
    script: "scripts/dev/lint-rust.sh",
    key: "clippy",
    warned: "Rust lint warnings",
    failed: "Rust lint failed",
  },
];

export default function droidPeekLint(pi: ExtensionAPI): void {
  pi.setLabel("Droid Peek lint");

  pi.on("turn_end", async (_event, ctx) => {
    for (const job of jobs) {
      const result = await pi.exec(
        "bash",
        [job.script, "--fix"],
        { cwd: ctx.cwd },
      );
      if (result.killed)
        return;

      const output = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
      if (result.code === 0 && output.length === 0) {
        ctx.ui.setStatus(job.key, "");
        continue;
      }

      const summary = output.split("\n").slice(0, 12).join("\n");
      ctx.ui.setStatus(
        job.key,
        result.code === 0 ? job.warned : job.failed,
      );
      if (ctx.hasUI && summary.length > 0)
        ctx.ui.notify(summary, result.code === 0 ? "warning" : "error");
    }
  });
}
