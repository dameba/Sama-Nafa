# Sama Nafa — Private Multi-Member Savings

Sama Nafa (“My Wallet” in Wolof) is a mobile-first savings-record platform for a private group of up to 25 active members.

## What's in this branch

- `index.html`: responsive interface with email/password sign-in, member dashboard, personal transactions, savings goals, and an administrator member view.
- `app-config.js`: public Supabase project URL and publishable key placeholders only.
- `supabase/schema.sql`: tables, member profile creation trigger, row-level security policies, and role separation.
- `supabase/functions/invite-member/index.ts`: administrator-only invitation function enforcing the 25-active-member cap.

This branch is an integration foundation, not yet a production-ready financial system. Member invitation, authentication and database features require the setup below. Member suspension UI, audited corrections, automated tests and a security review remain future work.

## Security and financial limitations

- Never commit a Supabase service-role key or any private key to GitHub or browser code.
- The browser publishable key is not a secret; row-level security is what protects the data.
- Members can only read their own profile, transactions and goals. Active administrators can read group profiles and transactions.
- Transaction records are append-only from the client. This initial version does not provide an audited correction workflow.
- The app records savings; it does not hold, verify, deposit, or transfer real money.
- This has not yet undergone a security audit. Do not use it for sensitive or real-money operations until setup, authorization tests, backups and security review are complete.

## Setup guide

### 1. Create a Supabase project
Create a new project at https://database.new. Keep the database password private.

### 2. Create the database schema
Open **SQL Editor** in Supabase, paste the complete contents of `supabase/schema.sql`, and run it. Review any SQL errors before proceeding.

### 3. Configure the public app connection
In Supabase Project Settings / API (or the Connect dialog), copy the **Project URL** and **publishable key**. Edit `app-config.js` and replace:
- `YOUR_SUPABASE_PROJECT_URL` with the project URL
- `YOUR_SUPABASE_PUBLISHABLE_KEY` with the publishable key

These two values are intended for the browser. Never put the service-role key in `app-config.js`.

### 4. Deploy the invitation function
Install and sign in to the Supabase CLI, then from this repository run:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase secrets set SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY
supabase functions deploy invite-member
```

Use the service-role key only in the Supabase function's server-side secrets. Never share it in chat or commit it to GitHub. For email invitations, configure Supabase Auth's Site URL and allowed redirect URLs to match the deployed Sama Nafa URL, and configure email delivery as required.

### 5. Create the first administrator
1. In Supabase Authentication, invite or create your own user with your private administrator email.
2. Verify the user exists in `auth.users` and the trigger created a row in `public.profiles`.
3. In the SQL Editor, run the following with your exact email address:

```sql
update public.profiles p
set role = 'admin'
from auth.users u
where p.id = u.id
  and u.email = 'YOUR_ADMIN_EMAIL';
```

Run this manually as the project owner only. Never provide a public client-side method to promote accounts to admin. Sign in to Sama Nafa using this account.

### 6. Deploy a separate Vercel project
Use Vercel **Add New → Project** and import `dameba/Sama-Nafa`. Select branch `secure-multimember-foundation` for a preview deployment while learning. Because this is a plain static HTML app, use the **Other** framework preset and leave the build command empty; the root directory is `./`. The app uses `app-config.js` at runtime, so make sure it has the correct public Supabase values before testing.

Do not merge this branch into `main` until the app has been tested. Existing projects are unrelated and should remain untouched.

## Before inviting members

Test at least two separate accounts:
1. Member A must see only Member A's own profile, transactions and goals.
2. Member B must not be able to query Member A's data, even by changing browser requests.
3. A member must not access the administrator invitation function.
4. The 26th active account must be rejected by the invitation function.
5. The administrator must be able to see group records.
6. Suspended users must lose access after suspension is implemented and tested.

The SQL uses Postgres Row Level Security; verify policies with dedicated allow/deny tests before handling real personal data.
