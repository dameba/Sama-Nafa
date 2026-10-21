# Sama Nafa — My Wallet

Sama Nafa is a modern, mobile-first personal savings tracker inspired by Senegalese culture. The name is intended to evoke “my wallet.”

**Tagline:** My wallet. My future.

## Prototype features
- Savings overview with live balance calculations
- Record flexible deposits on any day (including Sunday) without a required fixed amount
- Record withdrawals up to the recorded balance
- Transaction history
- Savings goals and progress
- Monthly deposit chart
- Responsive desktop and mobile navigation
- Browser-local data storage

## Important prototype limitation
This is a learning prototype and personal record keeper. It is **not a bank, wallet provider, or payment service**. Recording a transaction does not move real money. Data is stored in the current browser using localStorage and is not synchronized between devices or protected by an account login. Do not use real account credentials, payment details, or confidential financial data.

## Run locally
Open `index.html` in a modern browser. No build command or framework is needed for this first version.

## Deploy to Vercel
1. Open Vercel and select **Add New → Project**.
2. Import the GitHub repository `dameba/Sama-Nafa`.
3. Select the `main` branch.
4. For this static HTML prototype, no framework preset or build command is required; the root directory should remain `./`.
5. Click **Deploy**. Vercel should serve `index.html` as the site homepage.
6. After the first deployment, future commits to the connected branch can trigger new deployments.

## Next learning steps
- Preview the app and check the mobile layout.
- Add editing and export options for recorded transactions.
- Before using this for sensitive financial information, plan secure authentication, server-side storage, backups, privacy protections, and security review.
- Any future real-money transfers, payment processing, or banking functionality would require a suitable regulated provider and applicable approvals.
