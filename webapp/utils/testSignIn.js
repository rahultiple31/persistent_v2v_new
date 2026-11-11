// Temporary test sign-in. While its secret in Secrets Manager holds a password, the proxy
// says so at GET /api/test-sign-in, and the app asks for the test password instead of sending the agent to
// the identity provider. See proxy/src/services/testSignIn.js.
import { LOGGER_PREFIX } from "../constants";
import { SESSION_REQUEST_HEADERS } from "./serverSession";

const TEST_SIGN_IN_PATH = "/api/test-sign-in";

/** True when the proxy's test sign-in is switched on. Never throws. */
export async function isTestSignInOn() {
  try {
    const response = await fetch(TEST_SIGN_IN_PATH, { cache: "no-store", credentials: "same-origin" });
    return response.ok && (await response.json()).enabled === true;
  } catch {
    return false;
  }
}

const ERROR_TEXT = {
  401: "Wrong password.",
  404: "Test sign-in has just been switched off. Reload the page.",
  429: "Too many attempts. Wait a minute and try again.",
  400: "Use letters, numbers, spaces, dots, dashes or underscores in the name (up to 40).",
};

/**
 * Shows the test password form until a sign-in succeeds; resolves with the proxy's { accessToken, expiresAt },
 * or with the server-side sign-in { signedIn, test, expiresAt } (the proxy set the session cookie).
 */
export function askForTestSignIn() {
  return new Promise((resolve) => {
    const overlay = document.createElement("div");
    Object.assign(overlay.style, {
      position: "fixed",
      inset: "0",
      zIndex: "10001",
      background: "rgba(0, 0, 0, 0.45)",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
    });
    const form = document.createElement("form");
    Object.assign(form.style, {
      background: "#fff",
      padding: "24px",
      borderRadius: "8px",
      width: "min(360px, calc(100vw - 32px))",
      display: "flex",
      flexDirection: "column",
      gap: "10px",
      boxShadow: "0 4px 16px rgba(0, 0, 0, 0.25)",
    });
    const title = document.createElement("h5");
    title.textContent = "Test sign-in";
    const note = document.createElement("small");
    note.textContent = "Temporary access for testing this site. Use the test password you were given.";
    const name = document.createElement("input");
    Object.assign(name, { type: "text", placeholder: "Your name", maxLength: 40, className: "form-control", autocomplete: "name" });
    const password = document.createElement("input");
    Object.assign(password, { type: "password", placeholder: "Test password", required: true, className: "form-control", autocomplete: "current-password" });
    const error = document.createElement("small");
    error.style.color = "#b00020";
    const button = document.createElement("button");
    Object.assign(button, { type: "submit", textContent: "Sign in", className: "btn btn-primary" });
    form.append(title, note, name, password, error, button);
    overlay.append(form);
    document.body.append(overlay);
    name.focus();

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      button.disabled = true;
      error.textContent = "";
      try {
        const response = await fetch(TEST_SIGN_IN_PATH, {
          method: "POST",
          // The request header is required by the server-side sign-in (it stops forged sign-ins from other sites).
          headers: { "Content-Type": "application/json", ...SESSION_REQUEST_HEADERS },
          credentials: "same-origin",
          body: JSON.stringify({ name: name.value.trim(), password: password.value }),
        });
        if (response.ok) {
          overlay.remove();
          console.info(`${LOGGER_PREFIX} - test sign-in succeeded`);
          resolve(await response.json());
          return;
        }
        error.textContent = ERROR_TEXT[response.status] ?? `Sign-in failed (HTTP ${response.status}).`;
      } catch (err) {
        console.error(`${LOGGER_PREFIX} - test sign-in failed`, err);
        error.textContent = "The site could not be reached. Try again.";
      }
      password.value = "";
      button.disabled = false;
      password.focus();
    });
  });
}
