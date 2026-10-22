import { open } from "node:fs/promises";
import { dirname } from "node:path";
import { CustomEditor, stripFrontmatter, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Input, Key, matchesKey, truncateToWidth, visibleWidth, wrapTextWithAnsi, type AutocompleteProvider } from "@earendil-works/pi-tui";

type Skill = { name: string; description: string; filePath?: string };
type Reference = { prefix: string; name: string; start: number; end: number; token: string };
const escapeAttribute = (text: string) => text.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
function inCode(text: string, offset: number) {
	let fence = "", inline = "";
	for (const line of text.slice(0, offset).split("\n")) {
		const marker = /^ {0,3}(`{3,}|~{3,})/.exec(line);
		if (fence) {
			if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length && !line.slice(marker[0].length).trim()) fence = "";
			continue;
		}
		if (marker) { fence = marker[1]; inline = ""; continue; }
		for (const match of line.matchAll(/`+/g)) {
			const escapes = /\\*$/.exec(line.slice(0, match.index))![0].length;
			if (escapes % 2) continue;
			if (!inline) inline = match[0];
			else if (match[0] === inline) inline = "";
		}
	}
	return !!(fence || inline);
}
const unsafeContinuation = (after: string) => /^[A-Za-z0-9_\/\\:@$=\-]/.test(after) || /^\.[A-Za-z0-9_]/.test(after);
function references(text: string, partial = false): Reference[] {
	const result: Reference[] = [];
	if (text.trimStart().startsWith("!")) return result;
	for (const match of text.matchAll(/(^|[\s([{])([$\/])((?:skill:)?[a-z0-9-]*)/g)) {
		const start = match.index! + match[1].length, end = match.index! + match[0].length;
		if (partial && end !== text.length) continue;
		if (unsafeContinuation(text.slice(end))) continue;
		if (inCode(text, start) || (match[2] === "$" && match[3].includes(":"))) continue;
		result.push({ prefix: match[2], name: match[3].replace(/^skill:/, ""), start, end, token: text.slice(start, end) });
	}
	return result;
}
function completionReference(lines: string[], line: number, col: number) {
	const before = [...lines.slice(0, line), (lines[line] ?? "").slice(0, col)].join("\n");
	const ref = references(before, true).at(-1);
	const after = (lines[line] ?? "").slice(col);
	const suffix = /^[a-z0-9-]*/.exec(after)![0];
	return ref && !unsafeContinuation(after.slice(suffix.length)) ? ref : undefined;
}
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });
function paintEditorLine(line: string, ranges: { col: number; length: number }[], paint: (text: string) => string) {
	let output = "", column = 0, offset = 0;
	const plain = (text: string) => {
		let chunk = "", highlighted = false;
		const flush = () => { if (chunk) output += highlighted ? paint(chunk) : chunk; chunk = ""; };
		for (const { segment } of graphemes.segment(text)) {
			const width = visibleWidth(segment);
			const selected = ranges.some(r => column >= r.col && column + width <= r.col + r.length);
			if (selected !== highlighted) { flush(); highlighted = selected; }
			chunk += segment; column += width;
		}
		flush();
	};
	// Copy ANSI and Pi cursor markers exactly once, rather than slicing them as
	// styling prefixes (which would duplicate cursor/fake-cursor markers).
	for (const match of line.matchAll(/\x1b(?:\[[0-?]*[ -/]*[@-~]|[\]_][\s\S]*?(?:\x07|\x1b\\))/g)) {
		plain(line.slice(offset, match.index)); output += match[0]; offset = match.index! + match[0].length;
	}
	plain(line.slice(offset)); return output;
}
class InlineSkillEditor extends CustomEditor {
	inventory: () => Skill[] = () => [];
	paintSkill: (text: string) => string = text => text;
	onReady: (names: string[]) => void = () => {};
	private checked = new Map<string, { path?: string; state: "pending" | "ready" | "invalid" }>();
	private readyLabel = "";

	private validate(text: string) {
		const names = new Set(references(text).map(ref => ref.name));
		const selected = this.inventory().filter(skill => names.has(skill.name)).slice(0, 8);
		for (const name of this.checked.keys()) if (!selected.some(s => s.name === name)) this.checked.delete(name);
		for (const skill of selected) {
			if (this.checked.get(skill.name)?.path === skill.filePath) continue;
			const check = { path: skill.filePath, state: "pending" as "pending" | "ready" | "invalid" };
			this.checked.set(skill.name, check);
			void skillBlock(skill).then(() => {
				if (this.checked.get(skill.name) !== check) return;
				check.state = "ready"; this.tui.requestRender();
			}).catch(() => { if (this.checked.get(skill.name) === check) { check.state = "invalid"; this.tui.requestRender(); } });
		}
		const ready = selected.filter(skill => this.checked.get(skill.name)?.state === "ready").map(skill => skill.name);
		if (ready.join(",") !== this.readyLabel) { this.readyLabel = ready.join(","); this.onReady(ready); }
	}

	render(width: number): string[] {
		const text = this.getText(); this.validate(text);
		const lines = super.render(width);
		const selected = references(text).filter(ref => this.checked.get(ref.name)?.state === "ready");
		if (!selected.length) return lines;
		// Pi 1.3's layout rows preserve source substrings. Map confirmed source ranges
		// onto visible editor rows; never colour borders, completion menus or literals.
		const native = this as unknown as { paddingX: number; scrollOffset: number; renderedVisibleLineCount: number; layoutText(width: number): { text: string }[] };
		const padding = Math.min(native.paddingX, Math.max(0, Math.floor((width - 1) / 2)));
		const layout = native.layoutText(Math.max(1, width - padding * 2 - (padding ? 0 : 1)));
		let source = 0;
		for (let row = 0; row < layout.length; row++) {
			const raw = layout[row].text, start = text.indexOf(raw, source);
			if (start < 0) continue;
			source = start + raw.length;
			const visible = row - native.scrollOffset;
			if (visible < 0 || visible >= native.renderedVisibleLineCount || !raw) continue;
			const ranges: { col: number; length: number }[] = [];
			for (const ref of selected) {
				const from = Math.max(ref.start, start), to = Math.min(ref.end, source);
				if (from >= to) continue;
				const col = padding + visibleWidth(raw.slice(0, from - start));
				const length = visibleWidth(raw.slice(from - start, to - start));
				ranges.push({ col, length });
			}
			lines[visible + 1] = paintEditorLine(lines[visible + 1], ranges, this.paintSkill);
		}
		return lines;
	}

	handleInput(data: string) {
		if (matchesKey(data, "enter") && this.isShowingAutocomplete()) {
			const native = this as unknown as { autocompleteList?: { getSelectedItem(): { value: string } | undefined } };
			const selected = native.autocompleteList?.getSelectedItem();
			const name = /^(?:\/?skill:|\$)([a-z0-9][a-z0-9-]*)$/.exec(selected?.value.trim() ?? "")?.[1];
			const { line, col } = this.getCursor();
			if (name && completionReference(this.getLines(), line, col) && this.inventory().some(skill => skill.name === name)) {
				// Native slash-confirm falls through to submit; Tab only inserts.
				super.handleInput("\t");
				return;
			}
		}
		super.handleInput(data);
		if (!matchesKey(data, "/")) return;
		const { line, col } = this.getCursor();
		const ref = completionReference(this.getLines(), line, col);
		if (ref?.prefix !== "/" || ref.start === 0) return;
		// Pi 1.3 excludes '/' from provider triggerCharacters. Reuse its verified
		// autocomplete request without synthetic Tab, which could auto-select.
		(this as unknown as { tryTriggerAutocomplete(explicitTab?: boolean): void }).tryTriggerAutocomplete(false);
	}
}
async function skillBlock(skill: Skill) {
	if (!skill.filePath) throw new Error(`No trusted source path for skill ${skill.name}.`);
	const file = await open(skill.filePath, "r");
	try {
		const bytes = Buffer.alloc(128 * 1024 + 1);
		const { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
		if (bytesRead > 128 * 1024) throw new Error(`Skill ${skill.name} exceeds the inline 128 KiB limit; use its native command separately.`);
		return `<skill name="${escapeAttribute(skill.name)}" location="${escapeAttribute(skill.filePath)}">\nReferences are relative to ${dirname(skill.filePath)}.\n\n${stripFrontmatter(bytes.subarray(0, bytesRead).toString("utf8"))}\n</skill>`;
	} finally { await file.close(); }
}
const search = (skills: Skill[], query: string) => {
	const normalized = query.toLowerCase().trim();
	const words = normalized.split(/\s+/).filter(Boolean);
	const rank = (s: Skill) => s.name === normalized ? 0 : s.name.startsWith(normalized) ? 1 : 2;
	return skills.filter(s => words.every(word => `${s.name} ${s.description}`.toLowerCase().includes(word)))
		.sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
};

export default function (pi: ExtensionAPI) {
	// Reuse Pi's trusted resource inventory, including explicitly-invoked-only skills.
	// Never independently scan a repository or bypass its trust decision.
	const skills = (): Skill[] => pi.getCommands().filter(c => c.source === "skill")
		.map(c => ({ name: c.name.replace(/^skill:/, ""), description: c.description ?? "", filePath: c.sourceInfo?.path }))
		.sort((a, b) => a.name.localeCompare(b.name));

	async function pick(query: string, ctx: ExtensionContext) {
		const all = skills();
		if (!ctx.hasUI || !all.length) { ctx.ui.notify("No discoverable skills/UI available.", "warning"); return; }
		let selected: string | undefined;
		if (ctx.mode === "tui") {
			selected = await ctx.ui.custom<string | undefined>((tui, theme, _keys, done) => {
				const input = new Input(); input.setValue(query);
				let filtered = search(all, query), index = 0;
				return {
					get focused() { return input.focused; },
					set focused(value: boolean) { input.focused = value; },
					render(width: number) {
						width = Math.max(1, width);
						const lines = [truncateToWidth(theme.fg("accent", `Skills (${filtered.length}/${all.length}) — search name or description`), width), ...input.render(width), ""];
						const start = Math.max(0, index - 5);
						for (let n = start; n < Math.min(filtered.length, start + 8); n++) {
							const s = filtered[n];
							lines.push(truncateToWidth(theme.fg(n === index ? "accent" : "text", `${n === index ? ">" : " "} ${s.name} — ${s.description}`), width));
						}
						const current = filtered[index];
						lines.push("", ...wrapTextWithAnsi(current?.description || "No matching skills.", width), "",
							truncateToWidth(theme.fg("dim", "↑↓ choose • type to filter • Enter insert • Esc cancel"), width));
						return lines;
					},
					invalidate() { input.invalidate(); },
					handleInput(data: string) {
						if (matchesKey(data, Key.escape)) { done(undefined); return; }
						if (matchesKey(data, Key.enter)) { if (filtered[index]) done(filtered[index].name); return; }
						if (matchesKey(data, Key.up)) index = Math.max(0, index - 1);
						else if (matchesKey(data, Key.down)) index = Math.min(Math.max(0, filtered.length - 1), index + 1);
						else { input.handleInput(data); filtered = search(all, input.getValue()); index = 0; }
						tui.requestRender();
					},
				};
			});
		} else {
			const queryText = await ctx.ui.input("Search ALL skills by name or description (blank shows all)", query);
			if (queryText === undefined) return;
			const filtered = search(all, queryText);
			if (!filtered.length) { ctx.ui.notify("No matching skills.", "info"); return; }
			const options = filtered.map(s => `${s.name} — ${s.description}`);
			const choice = await ctx.ui.select(`Skills (${filtered.length}/${all.length})`, options);
			const index = options.indexOf(choice ?? "");
			if (index >= 0) selected = filtered[index].name;
		}
		if (selected) ctx.ui.setEditorText(`/skill:${selected} `);
	}
	pi.registerCommand("skills", {
		description: "Browse/search all loaded skills with full descriptions; insert one into your prompt",
		getArgumentCompletions: prefix => search(skills(), prefix).map(s => ({ value: s.name, label: s.name, description: s.description })),
		handler: pick,
	});
	pi.on("input", async (event, ctx) => {
		if (event.source === "extension") return { action: "continue" };
		if (event.text.trim() === "$") { await pick("", ctx); return { action: "handled" }; }
		const inventory = skills();
		const selected = [...new Set(references(event.text).map(ref => ref.name))]
			.map(name => inventory.find(s => s.name === name)).filter((s): s is Skill => !!s);
		if (!selected.length) return { action: "continue" };
		try {
			if (selected.length > 8) throw new Error("Select at most 8 inline skills per prompt.");
			const blocks = await Promise.all(selected.map(skillBlock));
			return { action: "transform", text: `${blocks.join("\n\n")}\n\n${event.text}`, images: event.images };
		} catch (error) {
			ctx.ui.notify(`Could not load the selected skill: ${String(error)}. Your request was not submitted.`, "error");
			return { action: "handled" };
		}
	});
	let autocompleteInstalled = false;
	pi.on("session_start", (_event, ctx) => {
		if (ctx.mode !== "tui" || autocompleteInstalled) return;
		autocompleteInstalled = true;
		ctx.ui.setEditorComponent((tui, theme, keys) => {
			const editor = new InlineSkillEditor(tui, theme, keys);
			editor.inventory = skills;
			editor.paintSkill = text => ctx.ui.theme.fg("success", text);
			editor.onReady = names => ctx.ui.setStatus("selected-skills", names.length ? `Skills ready: ${names.join(", ")}` : undefined);
			return editor;
		});
		ctx.ui.addAutocompleteProvider((current: AutocompleteProvider) => ({
			triggerCharacters: [...new Set([...(current.triggerCharacters ?? []), "$", "/"])],
			async getSuggestions(lines, cursorLine, cursorCol, options) {
				const ref = completionReference(lines, cursorLine, cursorCol);
				// Preserve Pi's application-command menu at the beginning of a prompt.
				if (!ref || (ref.prefix === "/" && ref.start === 0)) return current.getSuggestions(lines, cursorLine, cursorCol, options);
				const matches = search(skills(), ref.name);
				if (!matches.length) return current.getSuggestions(lines, cursorLine, cursorCol, options);
				return { prefix: ref.token, items: matches.map(s => ({ value: ref.prefix === "/" ? `/skill:${s.name}` : `$${s.name}`, label: `${ref.prefix}${s.name}`, description: s.description })) };
			},
			applyCompletion(lines, cursorLine, cursorCol, item, prefix) {
				const ref = completionReference(lines, cursorLine, cursorCol);
				const skillItem = item.value.startsWith("$") || item.value.startsWith("/skill:");
				if (!ref && skillItem) return { lines, cursorLine, cursorCol };
				if (!ref || (ref.prefix === "/" && ref.start === 0) || !skillItem) {
					return current.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
				}
				const start = cursorCol - prefix.length, line = lines[cursorLine];
				const rest = line.slice(cursorCol).replace(/^[a-z0-9-]*/, "");
				const space = rest.length ? "" : " ";
				const updated = [...lines]; updated[cursorLine] = line.slice(0, start) + item.value + space + rest;
				return { lines: updated, cursorLine, cursorCol: start + item.value.length + (rest.startsWith(" ") ? 1 : space.length) };
			},
			shouldTriggerFileCompletion: (...args) => current.shouldTriggerFileCompletion?.(...args) ?? true,
		}));
	});
}
