# A POL Net pilot town: a template any town can use

The idea: make WEBOCTA real in one place first. Local organisations fund tasks that make the town better, residents who join POL Net do them and are paid, older and at-risk residents get protected mode and family help, and Olo answers local questions from sources people can check. One working town is easier to understand, fund and copy than any promise about the whole internet.

This is a template. Fill in the town, the partners and the numbers; nothing here has started yet.

## What a pilot needs

| Piece | Who | What they do |
|---|---|---|
| A lead organisation | A council team, a community foundation, a university civic team, or a large local charity | Hosts the pilot locally, approves task posters, chairs a monthly review |
| Funders | The lead organisation, local grant makers, a business improvement district, research grants | Fund tasks (rewards plus the disclosed POL Net fee) and the support costs |
| Task posters | Charities, the council, local news, environmental and accessibility groups | Post tasks with clear instructions and review the work within a week |
| Members | Residents aged 18 and over | Join POL Net (one Proof-of-Life check), do tasks, report scams |
| Scam-protection partners | Organisations that already support older residents, Citizens Advice style services, libraries | Help people set up protected mode and family help, run drop-in sessions |
| Helius Network | Hashim Ruan | Runs POL Net, approves posters, handles payouts and support, publishes results |

## Before launch (prerequisites in the code and the law)

1. Proof-of-Life deployed (its DEPLOY.md) and the POL Net API deployed (apps/polnet/DEPLOY.md), both migrations applied.
2. Signed Mac app, and a Windows build, since most residents will not use a Mac.
3. Payouts: legal advice on worker status, Stripe Connect terms and the 18+ age limit (docs/POLNET.md, "Before payouts go live"). Until then, tasks can run with funding marked received and payouts held, with members told plainly.
4. An external security review of the server and browser.
5. A data protection impact assessment for the pilot, even though POL Net stores no personal data, because the lead organisation will ask for one.

## Twelve weeks

| Weeks | What happens |
|---|---|
| 1 to 2 | Sign the lead organisation and two or three task posters. Agree the budget, the review panel, and the measures below. Adapt `apps/polnet/pilot/tasks.json` to local needs. |
| 3 to 4 | Approve posters (`POST /v1/admin/posters/:id`), post and fund the first tasks. Run two set-up sessions at a library for protected mode and family help. |
| 5 to 10 | Open to residents. Weekly: review queue cleared by posters, scam reports checked, payouts made. Fortnightly: a short public update. |
| 11 to 12 | Collect results, interview members, posters and helpers, publish the report, decide whether to continue or stop. |

## Posting the templates

Each template in `apps/polnet/pilot/tasks.json` has a title, category, description, instructions, expected minutes, a suggested reward and slots. With an approved poster's member pass:

```
POST /v1/org/tasks
{ "title": "...", "description": "...", "instructions": "...", "category": "accessibility", "reward_pence": 1800, "slots": 10 }
```

then fund it through Stripe Checkout (`POST /v1/org/tasks/:id/fund`) or have Helius Network mark a bank transfer or grant received (`POST /v1/admin/tasks/:id/fund`). Set rewards with the funder so the expected hourly rate is at least the National Living Wage.

## What to measure (and publish, good or bad)

- Members who joined, and members who completed at least one task.
- Money paid to members, and the median hourly rate actually earned (from the minutes each member reports).
- Tasks completed and approved, and the time from submission to review.
- Useful outputs: places mapped, problems reported and fixed by the council, leaflets translated, claims checked.
- Scam protection: residents set up with protected mode, helpers linked, warnings shown by kind, and any scam stopped that the person or a helper tells us about. Count only what people report; POL Net does not watch anyone.
- Complaints and problems, and what changed because of them.

## Risks and how the pilot handles them

- **Low uptake.** Start with tasks that pay fairly and are easy to begin; partner with groups that already have volunteers.
- **Poor-quality or fake work.** One verified person per account, posters review every submission, and three member reports close a task.
- **Exploitative tasks.** Helius Network approves every poster and refuses engagement or click work (docs/POLNET.md, "Rules that keep it honest").
- **People who are not online.** Library sessions and helpers; POL Net is one route, not the only one.
- **Over-promising.** Members are told plainly that tasks are occasional paid work, not a living.

## How to say it

"A twelve-week pilot in {town}: residents are paid for work that makes the town better, local groups can prove their work was done by real people, and older residents get stronger protection from scams, with no tracking and no ads."
