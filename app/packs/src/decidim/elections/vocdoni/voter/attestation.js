import { ErrorCode, VoteError } from "src/decidim/elections/vocdoni/voter/errors";

/**
 * Asks Decidim to sign an attestation for the voter its census access let into
 * the booth. The body goes to the CSP's auth/0 as it is.
 *
 * @param {string} url - the booth config's `attestationUrl`.
 * @returns {Promise<Object>} `{ attestation, signature, contact?, salt? }`.
 */
export const fetchAttestation = async (url) => {
  const csrf = document.querySelector("meta[name='csrf-token']");
  let response = null;

  try {
    response = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "X-CSRF-Token": csrf
          ? csrf.content
          : ""
      }
    });
  } catch {
    throw new VoteError(ErrorCode.NETWORK);
  }

  if (!response.ok) {
    throw new VoteError(ErrorCode.AUTH_REJECTED);
  }

  return response.json();
};

export default fetchAttestation;
