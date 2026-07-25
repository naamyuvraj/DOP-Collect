import { cookies } from "next/headers";

export const COOKIE = "dop_admin";

/** The session token stored in the httpOnly cookie (derived from AUTH_SECRET). */
export function sessionToken() {
  return process.env.AUTH_SECRET || "dev-secret";
}

export function isAuthed() {
  return cookies().get(COOKIE)?.value === sessionToken();
}
