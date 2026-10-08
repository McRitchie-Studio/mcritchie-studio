# `secrets-rotation.md` hub key rotation record — archived 2026-10-07

Frozen record, ARCHIVE-ONLY. The dated account of the hub `SECRET_KEY_BASE`
rotation moved here verbatim from `docs/agents/system/secrets-rotation.md`
("Hub `SECRET_KEY_BASE`"). The live procedure is in that page. Do not edit this
file to keep it current.

---

The "Session cookie and every signed or encrypted cookie" row of the consumer table read:

| Session cookie and every signed or encrypted cookie | **Meant to survive** while `OLD_SECRET_KEY_BASE` holds the old key (`config/initializers/secret_key_base_rotation.rb`), with Rails re-writing each one under the new key on the visitor's next request. **It did not on 2026-10-07:** every pre-swap session signed out once, because the initializer derived the old key's cookie secrets with SHA1 while real cookies are sealed with SHA256. Task [`rotation-derives-old-key-sha256`](https://mcritchie.studio/tasks/rotation-derives-old-key-sha256) fixed it: the old key is now derived with SHA256 stated explicitly, and `verify_rotation` seals its probe the way a live request did. See the rotation log below |

The record below followed the procedure:

**Last rotation:** 2026-10-07 14:53:29Z (08:53 MDT), by Steffon. Heroku release v567 set both vars in one guarded Platform API PATCH. The key moved from `81febe43dd82180e` to `a084112568cb48e9` (16-character SHA-256 prefixes), and the stored digests matched. `verify_rotation` printed PASS. `/up` and `/signin` answered 200, board tokens re-minted, and `ErrorLog` held 0 rows in the 19 minutes after, against 7 the hour before. No rollback.

**Defect found in this run.** Pre-swap sessions did **not** survive. A `_studio_session` the web wrote at 14:51Z failed to read on the web after the swap, yet a direct `MessageEncryptor` opens it under the old key with SHA256. The cause is that `SecretKeyBaseRotation.apply!` calls `Rails.application.key_generator(old)` while `config/initializers` runs, which is before Active Support's `after_initialize` sets `KeyGenerator.hash_digest_class = SHA256`. That call memoizes a SHA1 generator in `@key_generators[old]`. Measured on a dyno, `app.key_generator(old)` equals the SHA1 derivation and not the SHA256 one. `verify_rotation` writes and reads through that same cached generator, so it passes without proving anything about a real cookie. The result is that `OLD_SECRET_KEY_BASE` helps no legitimate visitor, while a holder of the old key can still forge a session through the SHA1 derivation, so close the window at once. Before the next rotation, derive with `ActiveSupport::KeyGenerator.new(old, iterations: 1000, hash_digest_class: OpenSSL::Digest::SHA256)` and test against a cookie the request path wrote. That fix is task [`rotation-derives-old-key-sha256`](https://mcritchie.studio/tasks/rotation-derives-old-key-sha256): `SecretKeyBaseRotation.key_generator` derives with `HASH_DIGEST_CLASS` (SHA256) stated, and `verify` seals its probe from the app's configured digest, independent of that memo, with a SHA1 probe as a control that must not read. Its tests run `apply!` under the SHA1 class default, as the initializer meets it at boot, and the integration test does the same against a real signed-in session cookie.

**Window closed:** 2026-10-07 15:29:20Z (09:29 MDT), by Steffon, 36 minutes after the swap (task `close-old-hub-key-window`). Heroku release v568 removed `OLD_SECRET_KEY_BASE` in one guarded PATCH. `SECRET_KEY_BASE` was untouched and still reads `a084112568cb48e9`. After it, `verify_rotation` printed `old=EMPTY rotations signed=0 encrypted=0` and exited 1 (closed). `/up` and `/signin` answered 200, and a session created after the swap still read. In the 10 minutes after, `ErrorLog` recorded one unrelated row (a recurring Sidekiq job-uniqueness error), with no `InvalidSignature` or `InvalidMessage` and no 5xx. The three H27s logged were clients interrupted during the dyno restart.
