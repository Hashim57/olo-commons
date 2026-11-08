// Prints a new POLNET_SIGNING_JWK and POLNET_ADMIN_SECRET. Keep both in a password manager; never commit them.
//   deno run scripts/keys.ts
import { b64url, newSigningJwk } from "../supabase/functions/_shared/jwt.ts";
console.log(`POLNET_SIGNING_JWK='${await newSigningJwk()}'`);
console.log(`POLNET_ADMIN_SECRET='${b64url(crypto.getRandomValues(new Uint8Array(32)))}'`);
