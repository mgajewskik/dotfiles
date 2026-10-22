import { homedir } from "node:os";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Text, stripTerminalSequences, truncateToWidth } from "@earendil-works/pi-tui";

const empty = { render: () => [], invalidate() {} };
const plain = (text: string) => stripTerminalSequences(text)
	.replace(/[\x00-\x1f\x7f-\x9f]/g, " ").replace(/\s+/g, " ").trim();

function summary(args: Record<string, unknown>): string {
	const fields = ["action", "command", "path", "pattern", "url", "title", "description", "task", "id"];
	const values = fields.flatMap((key) => typeof args[key] === "string" ? [plain(args[key])] : []);
	const home = homedir();
	return values.map((value) => value === home || value.startsWith(`${home}/`)
		? `~${value.slice(home.length)}` : value).join(" · ");
}

/** Rendering only: Pi owns execution, results, per-tool clicks, and Ctrl+O. */
export default function (pi: ExtensionAPI) {
	pi.registerToolRenderer((name, next) => {
		const original = next();
		return {
			...original,
			renderShell: "self",
			renderCall(args, theme, context) {
				if (context.expanded) {
					// A compact component is not a valid cached component for another renderer.
					return original?.renderCall?.(args, theme, { ...context, lastComponent: undefined })
						?? new Text(`${name}\n${JSON.stringify(args, null, 2)}`, 0, 0);
				}
				const status = context.isError ? "failed" : context.isPartial
					? context.executionStarted ? "running" : "queued" : "done";
				const color = context.isError ? "error" : context.isPartial ? "warning" : "muted";
				const detail = summary(args);
				return {
					render(width) {
						return [truncateToWidth(
							theme.fg(color, `▸ ${status} `) + theme.fg("toolTitle", name)
								+ (detail ? theme.fg("muted", ` ${detail}`) : ""),
							Math.max(0, width), "…",
						)];
					},
					invalidate() {},
				};
			},
			renderResult(result, options, theme, context) {
				// Native renderers also finish streaming timers here, even when hidden.
				const component = original?.renderResult?.(result, options, theme, { ...context, lastComponent: undefined });
				if (!options.expanded) return empty;
				return component ?? new Text(result.content.filter((block) => block.type === "text")
					.map((block) => stripTerminalSequences(block.text)
						.replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, "")).join("\n"), 0, 0);
			},
		};
	});
}
