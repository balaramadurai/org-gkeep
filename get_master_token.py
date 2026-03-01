#!/usr/bin/env python3
"""Get a master token for gkeepapi authentication.

Method: Uses gpsoauth with an OAuth token from Google's embedded login flow.

Steps:
1. Open this URL in your browser (incognito recommended):
   https://accounts.google.com/EmbeddedSetup/identifier?flowName=EmbeddedSetupAndroid

2. Sign in with your Google account (complete 2FA if needed)

3. After sign-in, you'll see a "loading" page. Open browser DevTools (F12):
   - Go to Application > Cookies
   - Find the cookie named 'oauth_token'
   - Copy its value

4. Run this script:
   python3 get_master_token.py

5. Paste the oauth_token when prompted

6. Add the master token to your Emacs config (store securely!)
"""

import sys

try:
    import gpsoauth
except ImportError:
    print("Install gpsoauth first: pip install gpsoauth")
    sys.exit(1)


def main():
    email = input("Email: ").strip()
    oauth_token = input("OAuth Token (from cookie): ").strip()

    # Android ID can be any hex string for this purpose
    android_id = "0000000000000000"

    try:
        master_token = gpsoauth.exchange_token(email, oauth_token, android_id)
        print(f"\nMaster token:\n{master_token}\n")
        print("Add to your Emacs config:")
        print(f'(setq org-gkeep-master-token "{master_token}")')
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
