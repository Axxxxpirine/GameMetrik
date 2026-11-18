# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use GitHub's private reporting instead: on this repository, open the **Security** tab and choose **Report a vulnerability**. Describe what you found, how to reproduce it and what an attacker could gain. You will get an answer there.

This is a personal project maintained in spare time, so there is no guaranteed response delay.

## Scope

In scope: the code in this repository, in particular the keychain vault, the lock and unlock sequence, the encrypted cache, the connection transfer to the iPhone and the handling of provider credentials.

Out of scope: the providers themselves (Apple, Google, Firebase, AdMob, Supabase) and builds modified by third parties.

## Never commit credentials

GameMetrik reads provider credentials at run time and stores them in the keychain only. Nothing in this repository should ever contain a real key, token, service account file, `.env` file or `.gmconnection` transfer file. The test suite uses synthetic values and keys generated at run time. If you find a real credential in the history, report it privately as described above.
