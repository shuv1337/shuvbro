// Only transport extraction is shared. The native package owns exact-session
// guard registration; V1 keeps its existing factory and transport semantics.
export function commandFromTool(event) {
  if (!event || typeof event !== "object") return "";
  if (event.tool !== "shell" && event.tool !== "bash") return "";
  return typeof event.input?.command === "string" ? event.input.command : "";
}
