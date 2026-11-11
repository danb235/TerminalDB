# AWS session grouping and sign-in QA

Use synthetic profiles, SSO sessions, and fake AWS responses for recorded UI
scenarios. Never record real terminal contents, authorization codes, account
identifiers, credentials, or Keychain dialogs. Report automated and visible
results separately.

## Automated plan

- Profiles group under their SSO session header. **Sign In** is a visible
  button on the header in every signed-out or ended state, never only in a
  menu.
- A signed-in header reads **Signed in until** a time, with time left and
  "renews N profiles". It turns orange under 30 minutes. A passed estimate
  reads **Session may have ended** and offers **Sign In**. A sign-in in
  progress reads **Signing in…** with **Cancel**.
- Session length defaults to 8 hours, shortens to a measured value when a
  session ends early, and accepts a chosen length from 1 hour to 90 days or
  **Automatic**.
- **Extend…** ends only the selected SSO session, leaves other sessions on the
  Mac signed in, and starts a full browser sign-in. Issued access keeps
  working until it expires. **Sign In Without Ending Session** keeps the
  current end time.
- Each row shows name, account, role, and source (**On This Mac**, **Shared
  from This Mac**, or **From** a Mac). Its single status line covers Ready,
  Not shared, Access until, Expired, Access denied, Couldn't check access, and
  Can't reach AWS.
- A row shows at most one button, and only when an action is needed. The
  actions menu lists Check Access with the last checked time and the other
  profile actions. No Details page or Details wording remains.
- An ended SSO session with AWS reachable shows **Signed out** with **Sign
  In**, never **Check failed**. An unreachable AWS endpoint shows **Can't
  reach AWS** and does not ask for sign-in.
- Sharing opens as a secondary page with **Back** at the top, and returning
  restores the profile list.

## Visible plan

1. Through the normal app menu or the footer, open Accounts → AWS. Review the
   session headers and profile rows at the normal and narrow supported widths.
2. In a signed-in synthetic session, verify the end time, time left, profile
   count, and the orange state when under 30 minutes remain.
3. Switch the synthetic session to signed out. Verify **Signed out**, the
   header **Sign In**, and **Access until** or **Expired** on each row.
4. Start a sign-in and cancel it. Still-valid access remains and the header
   returns to its previous state.
5. Open the session's actions menu. Change **Session Length**, return it to
   **Automatic**, and confirm the header updates. Choose **Extend…** and
   confirm the explanation before cancelling.
6. Open a row's actions menu. Run **Check Access** and verify the last checked
   time updates in place without a browser sign-in.
7. Exercise denied access and an unreachable AWS endpoint. Neither offers
   **Sign In** as the required recovery.
8. Open **Sharing**, then use **Back** to return to the profiles.
9. Confirm the current app, paired-device trust, account configuration, and
   approved sharing remain intact. Remove temporary QA apps and helpers.

## Outcomes

Pending.
