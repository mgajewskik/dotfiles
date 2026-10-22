import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "ask_user",
		label: "Ask user",
		description: "Ask the user one or more questions. Omit options for a free-text answer, or provide 2–6 choices; a custom-answer option is always included. Option descriptions and recommendations are optional. Cancellation, blank input and unavailable UI are not answers or approval. Works in TUI and RPC; headless agents must pass unresolved questions to their parent or the user.",
		executionMode: "sequential",
		parameters: Type.Object({
			questions: Type.Array(Type.Object({
				question: Type.String({ minLength: 1, maxLength: 2000 }),
				options: Type.Optional(Type.Array(Type.Object({
					label: Type.String({ minLength: 1, maxLength: 200 }),
					description: Type.Optional(Type.String({ maxLength: 1000 })),
					tradeoff: Type.Optional(Type.String({ maxLength: 1000, description: "Optional alternative to description for existing callers" })),
				}), { minItems: 2, maxItems: 6 })),
				recommended: Type.Optional(Type.Integer({ minimum: 1, maximum: 6, description: "Optional one-based choice number" })),
				reason: Type.Optional(Type.String({ maxLength: 1000, description: "Optional explanation for the recommendation" })),
			}), { minItems: 1, maxItems: 6 }),
		}),
		async execute(_id, params, signal, _update, ctx) {
			const answers: { question: string; answer: string; custom: boolean }[] = [];
			const result = (status: "answered" | "cancelled" | "unavailable") => ({
				content: [{ type: "text" as const, text: JSON.stringify({ status, answers,
					...(status !== "answered" ? { instruction: "Unanswered questions remain unresolved. Do not assume an answer or approval." } : {}) }) }],
				details: { status, answers },
			});
			for (const q of params.questions) {
				if (q.recommended !== undefined && (!q.options || q.recommended > q.options.length)) {
					throw new Error("Recommended choice requires options and must be within their range.");
				}
			}
			if (!ctx.hasUI) return result("unavailable");
			for (let index = 0; index < params.questions.length; index++) {
				if (signal?.aborted) return result("cancelled");
				const q = params.questions[index];
				const title = `Q${index + 1}/${params.questions.length}: ${q.question}`;
				if (!q.options) {
					const answer = await ctx.ui.input(title, "Type your answer", { signal });
					if (!answer?.trim() || signal?.aborted) return result("cancelled");
					answers.push({ question: q.question, answer: answer.trim(), custom: true });
					continue;
				}
				const options = q.options.map((o, i) => {
					const note = o.description ?? o.tradeoff;
					return `${i + 1}. ${o.label}${i + 1 === q.recommended ? " (recommended)" : ""}${note ? ` — ${note}` : ""}`;
				});
				const other = "Other — type your own answer";
				const recommendation = q.recommended === undefined ? "" :
					`\nRecommendation: ${q.options[q.recommended - 1].label}${q.reason ? `. ${q.reason}` : ""}`;
				const selected = await ctx.ui.select(title + recommendation, [...options, other], { signal });
				if (!selected || signal?.aborted) return result("cancelled");
				if (selected === other) {
					const answer = await ctx.ui.input(q.question, "Type your own answer", { signal });
					if (!answer?.trim() || signal?.aborted) return result("cancelled");
					answers.push({ question: q.question, answer: answer.trim(), custom: true });
				} else {
					const choice = options.indexOf(selected);
					if (choice < 0) return result("cancelled");
					answers.push({ question: q.question, answer: q.options[choice].label, custom: false });
				}
			}
			return result("answered");
		},
	});
}
