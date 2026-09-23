export const PROTOCOL_VERSION = 1;
export const MAX_PAGE_EVENTS = 128;

const OPERATIONS = new Set(["publish", "pull", "ack", "outcome"]);

export function typedError(code, retryable = false, details = undefined) {
  const error = { type: "error", code, retryable };
  if (details !== undefined) error.details = details;
  return error;
}

export function validateEnvelope(message) {
  if (!message || typeof message !== "object" || Array.isArray(message)) {
    return typedError("INVALID_MESSAGE");
  }
  if (message.version !== PROTOCOL_VERSION) {
    return typedError("UNSUPPORTED_PROTOCOL");
  }
  if (!OPERATIONS.has(message.operation)) {
    return typedError("INVALID_OPERATION");
  }
  if (typeof message.profileId !== "string" || !message.profileId.trim()) {
    return typedError("INVALID_PROFILE");
  }
  return null;
}

export function isWebUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

export function isReceipt(response, status) {
  return response?.type === "receipt" && response.status === status;
}
