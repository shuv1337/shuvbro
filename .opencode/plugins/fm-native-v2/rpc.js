// Location routes the native package instance; it is never authority.
export const bindingRPC = {
  id: "firstmate.supervision",
  methods: {
    bindingStatus: {
      input: { type: "object", required: ["sessionID", "claimID"], additionalProperties: false,
        properties: { sessionID: { type: "string" }, claimID: { type: "string" } } },
      output: { type: "object", required: ["status"], additionalProperties: false,
        properties: { status: { type: "string", enum: ["valid", "stale", "unknown"] } } },
    },
  },
  events: {},
};
