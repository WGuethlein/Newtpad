# Newtpad — Commercial Market Research

**Compiled 2026-08-04.** Pricing, positioning, channels, and a dated launch sequence for shipping Newtpad as a paid Windows product.

Grounding: [CLAUDE.md](../../../../../../../E:/Code/Newtpad/CLAUDE.md) (thesis), [docs/features.md](../../../../../../../E:/Code/Newtpad/docs/features.md) (what works today, v0.33.0 baseline), and the existing corpus in [research/](../../../../../../../E:/Code/Newtpad/research/) — `demand-side-feature-research.md`, `newtpad-research-report.md`, the File Pilot BSC-2025 engine-talk notes and the Wookash interview notes.

**Evidence honesty.** Every competitor price below is either fetched from the vendor's own page or, where the vendor blocked the fetch, sourced to a named third party and labelled as such. Reddit is not directly fetchable from this environment (both `reddit.com` and `old.reddit.com` are blocked), so Reddit findings are search-summarised and are explicitly marked lower-confidence; the direct user quotes below come from Hacker News (via the Algolia API) and the Notepad++ community forum, which are fetchable. Search-volume claims for SEO are **not verified** — I had no keyword tool — and are flagged as such rather than guessed.

---

## 1. Competitive + pricing teardown

### 1.1 The table

| Product | Current price | Model | Upgrades | Free tier | Team size |
|---|---|---|---|---|---|
| **Windows Notepad** | $0 | Bundled with Windows | Windows Update | Is the free tier | Microsoft |
| **VS Code** | $0 | MIT-licensed core, free binaries | Free forever | Is the free tier | Microsoft, large |
| **Notepad++** | $0 | GPL, donation-funded | Free forever | Is the free tier | **Don Ho, sole maintainer** |
| **Notepad2 / Notepad3** | $0 | Open source | Free forever | Is the free tier | Notepad2: effectively dormant (last updates ~2012). Notepad3: active, Rizonesoft, latest 7.26.602.1 (2026-06-02) |
| **Sublime Text** | **$99** personal; business **$65/seat/yr** at 1–10 seats, sliding to $50/seat/yr at 50+ | Personal = **perpetual with a 3-year updates window**; business = annual subscription | After 3 years you must buy an upgrade to keep receiving updates | Unlimited fully-functional evaluation with a periodic nag | Sublime HQ — small private company (exact headcount **unverified**) |
| **EmEditor** | **$60 first year, $45/yr renewal**, or **$6/month** | **Subscription only** | Included while subscribed | **EmEditor Free** — the trial downgrades to a free version that still handles huge files and regex | **Emurasoft, founded by Yutaka Emura** — effectively one-person |
| **UltraEdit** | ~**$79.95/yr** subscription; perpetual from ~**$97.95** (UltraEdit Core, bundles UltraCompare); Enterprise perpetual ~$119.95/user; $59.95 to convert an existing perpetual to subscription | Both offered; perpetual includes 1 year of renewable maintenance | Maintenance renewal | Trial | IDM Computer Solutions — largest of the paid set (headcount **unverified**; their own pages 403'd this fetch, prices are from Capterra/ComponentSource aggregation) |
| **010 Editor** | **$149.95** commercial / **$59.95** home-academic | **Perpetual, non-expiring** | Upgrade/maintenance **$49.95** commercial / **$24.95** home | Trial (not advertised on the store page) | SweetScape Software — small |
| **EditPad Pro** *(added — closest structural analogue)* | **$59.95** single user | Perpetual; free minor updates and bug fixes; 3-month unconditional money-back guarantee | Major versions paid | EditPad Lite is free | **Just Great Software / Jan Goyvaerts — one person** |
| **Beyond Compare** *(added — paid Windows utility precedent)* | ~$35–60 depending on edition | Perpetual; **major version upgrades require a new purchase** | Paid | Trial | Scooter Software — small team |
| **File Pilot** | **Essential $50** ($40 early-bird), **Pro $250** ($200 early-bird). Team / Team Pro above that | **Perpetual.** Essential = 1 year of updates then you keep the last version; Pro = lifetime updates + VIP channel + priority support. All licences include all features; multiple devices per user | Essential holders pay again for another updates window | **Free public beta**, currently v0.8.2 | **Vjekoslav Krajačić, solo (Voidstar)** |

Sources: [sublimehq.com/store/text](https://sublimehq.com/store/text) · [emeditor.com/buy](https://www.emeditor.com/buy/) · [emeditor.com — ending sales of lifetime licenses](https://www.emeditor.com/general/license-price-update-and-ending-sales-of-lifetime-licenses/) · [en.wikipedia.org/wiki/EmEditor](https://en.wikipedia.org/wiki/EmEditor) · [ultraedit.com/pricing](https://www.ultraedit.com/pricing/) (403 to automated fetch; figures via [Capterra](https://www.capterra.com/p/183163/UltraEdit/) and [ComponentSource](https://www.componentsource.com/product/ultraedit/prices)) · [sweetscape.com/store](https://www.sweetscape.com/store/) · [editpadpro.com/buynow.html](https://www.editpadpro.com/buynow.html) · [componentsource.com/product/beyond-compare/prices](https://www.componentsource.com/product/beyond-compare/prices) · [filepilot.tech/pricing](https://filepilot.tech/pricing) (prices render client-side; dollar figures corroborated by [How-To Geek](https://www.howtogeek.com/third-party-file-manager-impressive-replaced-windows-file-explorer/), which quotes "$40" Essential / "$200" Pro) · [notepad-plus-plus.org/donate](https://notepad-plus-plus.org/donate/) · [github.com/rizonesoft/Notepad3](https://github.com/rizonesoft/Notepad3) · [flos-freeware.ch](https://www.flos-freeware.ch/)

### 1.2 What the team sizes tell us about achievable revenue

Six of the ten products above are one person or near enough: Notepad++ (Don Ho), EmEditor (Yutaka Emura), EditPad Pro (Jan Goyvaerts), 010 Editor, Beyond Compare, File Pilot. **Two of them have sustained a full-time income for 20+ years selling a text editor against a free default** (EmEditor since 1997, EditPad Pro since the late 1990s). That is the single most important commercial fact in this report: the "you can't sell a text editor, Notepad++ is free" objection has been empirically false for two decades, and the counter-examples are solo developers, not funded companies.

What no one publishes is units. File Pilot discloses no download or revenue numbers on [filepilot.handmade.network](https://filepilot.handmade.network/) or its site. **Any revenue projection here is a model, not a finding.** Treat the scenarios in §1.5 accordingly.

### 1.3 The structural read on the pricing landscape

Three things are true at once, and they define the opening:

1. **The subscription drift is real but not universal.** EmEditor ended lifetime licence sales on 2024-08-28 and is now subscription-only, having also raised the lifetime price from $260 to $380 before killing it ([announcement](https://www.emeditor.com/general/license-price-update-and-ending-sales-of-lifetime-licenses/)). UltraEdit pushes subscription and charges $59.95 to convert perpetual holders onto it. But 010 Editor, EditPad Pro, Beyond Compare and File Pilot all still sell perpetual, and Sublime sells perpetual-with-a-window.
2. **The perpetual survivors all use an updates window, not "free forever."** Sublime: 3 years. File Pilot Essential: 1 year. 010 Editor: paid upgrade releases. Beyond Compare: paid major versions. This is the settled solution to "perpetual licences don't fund ongoing work," and it is what Newtpad should copy rather than invent around.
3. **Free is not merely present, it is capable.** EmEditor's own trial *downgrades to a free version that still handles huge files and regex*. That matters enormously to §2: the large-file capability alone is available for $0 from the incumbent whose entire pitch is large files.

### 1.4 Recommendation: **$39 launch / $49 standard, perpetual, 12 months of updates included**

**The specific proposal.**

- **Newtpad Personal — $39** for the first 8 weeks or first 500 licences (whichever comes first), **$49** thereafter. The intro price is a real, dated, once-only launch window, not a permanent fake discount.
- **Perpetual licence.** Includes **12 months of updates**. When the window lapses you keep the last version you received, forever, fully functional. Optional **$19/year** renewal to resume updates — never required to keep using the product.
- **Commercial / per-seat licence — $69/seat**, same terms. (One extra SKU, not three. Principle 3: fight options.)
- **No subscription. No feature gating. No online activation. No telemetry.** Offline key file, honour-system, per-user across all their devices — File Pilot's and Sublime's model.
- **Trial: unlimited, fully functional, with a periodic non-blocking reminder.** Sublime's model exactly.

**Defence of $39/$49.**

- *It is the only number that is simultaneously below every paid competitor's entry point and above the "toy" line.* EmEditor's cheapest way in is now $60/yr; UltraEdit $79.95/yr; Sublime $99; 010 Editor $59.95 even at the home rate; EditPad Pro $59.95; File Pilot Essential $50. A $49 standard price is under all of them and *materially* under the two direct large-file competitors, whose renewals compound.
- *It prices against the right competitor.* Newtpad's honest competitive set today is EditPad Pro ($59.95) and File Pilot Essential ($50), not Sublime. [features.md](../../../../../../../E:/Code/Newtpad/docs/features.md) shows no multi-cursor, no diff, no macros, no code folding, no `.py` lexer, no complex-script shaping, two built-in themes, and two palette commands that are documented dead. Pricing at Sublime's $99 invites a feature-checklist comparison Newtpad loses on paper even where it wins in practice.
- *The elasticity between $39 and $59 is weak; the elasticity between $0 and $39 is everything.* The objection Newtpad faces is "why pay at all when Notepad++ is free," not "why $49 and not $39." Twenty dollars does not move that decision. What moves it is the trial being unlimited and the product being visibly better within ninety seconds. Hence: spend the pricing budget on being *cheaper than every paid rival* (a clean, defensible line in a comparison table) rather than on being *cheap*.
- *The intro window creates the only urgency a perpetual product ever gets.* File Pilot's 20% early-bird does the same job. Without it, a launch-day HN reader has no reason not to bookmark and forget.
- *The updates window is what makes the perpetual promise survivable.* Newtpad is one person's ongoing work. "Buy once, updates forever, $39" is a promise that gets more expensive to keep every year and has bankrupted this exact business model repeatedly — it is precisely why EmEditor killed lifetime licences after raising them to $380. A 12-month window with a cheap optional renewal is honest, is what the surviving perpetual vendors do, and lets a satisfied user opt into funding the work without a subscription's coercion.
- *Why not a File-Pilot-style $250 lifetime tier?* Because File Pilot could offer it after two years of public beta and a 331-point Hacker News front page had established that its audience loved it. Newtpad has no such reservoir on day one, and the [How-To Geek reviewer's reaction](https://www.howtogeek.com/third-party-file-manager-impressive-replaced-windows-file-explorer/) to File Pilot's tiers — "the pricing is definitely on the higher side... only a few users may be willing to pay such a high amount" — is the mainstream-press risk of anchoring high before you have proof. Revisit a lifetime tier at v1.5, priced around $129, once there is a track record to sell.

**What I would not do:** launch at $19 or $25. It reads as a utility, not a tool; it makes the support cost per licence indefensible; and it undercuts the product's own positioning, which is *quality*, not thrift. The corpus's own note from the File Pilot research — "quality-over-cheap pricing worked: File Pilot repaid the author's debts from beta pre-orders at 'spicy' prices" — points the same way.

### 1.5 Revenue scenarios (models, not findings)

At $39/$49 with an even split of intro and standard sales (~$44 average, ~$41 net after Paddle's 5% + 50¢):

| Scenario | Year-1 licences | Net revenue |
|---|---|---|
| HN post flops (<50 points), press ignores it | 80–250 | $3.3k–$10k |
| HN lands mid (100–200 points), one or two Windows outlets pick it up | 600–1,500 | $25k–$62k |
| HN front page at File Pilot scale (300+ points) plus the gHacks/XDA/How-To-Geek wave | 2,500–6,000 | $103k–$246k |

These are unverified extrapolations from the observed *attention* File Pilot received, not from any disclosed conversion data. Their only legitimate use is to show that the distribution of outcomes is dominated by whether one Hacker News post lands — which is why §3 ranks channels the way it does.

### 1.6 The counter-case for free / open-source with a paid tier — **rejected, with one concession accepted**

**The case for it, stated at full strength:**

- The entire competitive set at the top of the funnel is $0, and the hardest problem for a solo developer with no audience is distribution, not monetisation. Free removes the largest single drop-off in the funnel.
- Open source is this category's norm: Notepad++ (GPL, 28M+ downloads), Notepad3, VS Code's core, klogg, glogg. Being closed-source is a genuine friction with the Hacker News and r/programming audiences you most need.
- Package managers, corporate approval processes, and school/lab deployments all pass free software through with less resistance.
- The natural cut is obvious and defensible: free core editor; paid "Pro" = multi-GB mapped mode, the CSV grid, filter view, and the reformatters.

**Why I reject it:**

1. **The paid tier would have to be exactly the wedge.** The free/paid line above puts multi-GB handling, filter-to-matches and the CSV grid behind the paywall — which are the three things that make anyone switch (§2). A free tier that omits them is not compelling enough to build the audience; a free tier that includes them leaves nothing to sell. There is no cut of Newtpad that is both a good free product and leaves a good paid product.
2. **Two products, one person.** A free/Pro split is two SKUs, two support surfaces, two sets of "is this feature in my version" questions, and a permanent taxonomy argument with every new feature. It is a direct violation of principle 3 ("every added option signals leakage in core design") applied to the business rather than the UI.
3. **Open source buys contributions Newtpad cannot receive.** ~11k lines of Odin with a handmade D3D11 renderer and a hand-rolled DirectWrite COM seam has a contributor pool of approximately zero. You would take on issue triage, PR review, licence questions, and fork risk in exchange for goodwill.
4. **The closest analogue chose closed-and-paid and was rewarded anyway.** File Pilot is closed source, will cost $50–$250, and still hit [331 points and 221 comments on Hacker News](https://news.ycombinator.com/item?id=43091466) (2025-02-18), plus gHacks, BGR, How-To Geek and XDA coverage inside eight months. The handmade audience rewards *paid and honest*; it does not require open source.
5. **The twenty-year evidence is on the closed-paid side.** EmEditor and EditPad Pro have each sustained a person for two decades selling closed-source editors against free defaults. There is no comparable example of a free-core/paid-tier Windows text editor sustaining anyone.

**The concession I accept.** The genuine benefit of "free" is that reviewers, package managers, sceptics and Show HN readers can all *run the thing with zero friction*. Capture all of that without splitting the product: **an unlimited, fully-functional, no-signup, no-email trial with a periodic non-blocking reminder.** It satisfies Show HN's explicit "ideally without barriers such as signups or emails" requirement, lets Scoop and winget list it, lets gHacks test it, and costs nothing in product complexity. This is Sublime's model and it has held for fifteen years.

---

## 2. Positioning

### 2.1 Is the large-file wedge real? — **Validated as a credibility wedge, killed as the purchase wedge**

**Evidence for.** The failure is real, reproducible and quotable.

On the Notepad++ community forum thread titled ["I hate Notepad++ because the maximum file size it lets me open is only..."](https://community.notepad-plus-plus.org/topic/25955/i-hate-notepad-because-the-maximum-file-size-it-lets-me-open-is-only), user *mkupper* reports testing a 10 GB+ file: it opened in roughly 30 seconds and **consumed about 12 GB of RAM**, and a regex search **failed after 27 seconds with "Invalid regular expression"** because of Boost complexity limits. A ~4.4 GB file opened in 10 seconds, took ~5 GB RAM, and a regex search took **48 seconds**. User *Mark Olson* notes the plugin ecosystem "cannot work with files larger than 2^31 - 1 (about 2.1 billion) characters." The thread's own consensus is that things are fine "under 2–3 GB" — which is an admission, not a defence.

On Hacker News, user *8fingerlouie* on the "Editor Overload" thread ([comment 24303287](https://news.ycombinator.com/item?id=24303287), 2020-08-28): *"Sublime will use very little memory opening a large log file, VSCode is in the GB memory consumption range long before finishing reading it."* User *TuringTest* ([comment 37220397](https://news.ycombinator.com/item?id=37220397), 2023-08-22): *"Notepad++ may be extremely slow to open if you have a previous tab with a huge file."*

A whole tool category exists solely because mainstream editors fail here: **klogg has 3,461 GitHub stars and 322 forks** ([api.github.com/repos/variar/klogg](https://api.github.com/repos/variar/klogg)) and describes itself as a "really fast log explorer," and it is a fork of glogg, which existed for the same reason. gHacks' 2018 article ["How to open Gigabyte-sized text files on Windows"](https://www.ghacks.net/2018/02/22/how-to-open-gigabyte-sized-text-files-on-windows/) is still cited and still ranks eight years later — evergreen search demand is the strongest single indicator here. And [EmEditor's entire commercial pitch](https://www.emeditor.com/text-editor-features/large-file-support/optimized-sort/) is that it opens files "up to 248 GB or 2.1 billion lines" — a subscription business built on exactly this pain, which proves the willingness to pay.

**Evidence against — and it is serious.**

- **The large-file audience's existing answers are free.** klogg, glogg, LogExpert, Large Text File Viewer, browser-based viewers, and — critically — **EmEditor Free**, which per [Wikipedia](https://en.wikipedia.org/wiki/EmEditor) "still can handle huge files and regex" after the trial downgrades. The one capability you were going to charge for is the one the incumbent gives away.
- **The pain is episodic.** A sysadmin meets a 10 GB log a handful of times a year. Low-frequency pain is the worst possible foundation for a purchase decision, because the moment of pain and the moment of payment are far apart and the free workaround is one search away.
- **The complaint volume is thin.** A deliberate sweep of Hacker News comments for large-file editor complaints returned a handful of hits over six years, not a chorus. This is a real pain, not a loud one.

**Verdict: large-file handling is the *demo*, not the *pitch*.** It is what makes a 30-second screen capture undeniable, what earns the Show HN comment thread and the gHacks writeup, and what makes the product *credible*. It is not what makes someone open their wallet, because there is a free tool for it and they need it four times a year.

This partially **contradicts** `demand-side-feature-research.md` §B.2, which treats filter-to-matching-lines and large-file handling as the load-bearing conversion feature ("Without it, V1 for a log user is just a fast editor that opens big files"). That was correct as *feature prioritisation* — and Newtpad shipped it, correctly. It is wrong as *positioning*: the free competition at exactly that capability was never assessed.

### 2.2 The actual wedge: **the second window**

Nobody replaces VS Code with Newtpad. Nobody replaces Notepad++ *because it is slow*, because for a 400 KB config file it isn't.

The buyer is the person who has **two text windows open all day**. One is their IDE, where the project lives. The other is where everything else lands: a log they are tailing, a CSV a client emailed, a `.env` they are diffing by eye, a stack trace pasted from Slack, a `web.config`, a scratch buffer of half-finished commands. Today that second window is Notepad++, and it is Notepad++ by inertia, not by love.

**The specific buyer: the Windows sysadmin / DevOps / support / data-ops engineer, and the Windows developer's non-IDE window.** These people already pay for Windows tools — Beyond Compare, Directory Opus, Royal TS, mRemoteNG-adjacent commercial kit — and they buy on "this removes a daily annoyance," not on "this is cheaper."

**The three capabilities that close that sale**, all of them shipping today per [features.md](../../../../../../../E:/Code/Newtpad/docs/features.md):

1. **It never locks your file, and it follows a growing log.** Newtpad opens share-read/write/delete and closes the handle immediately; a file that only grew is absorbed as an append with caret, selection, search results and bookmarks all keeping their meaning, and the view following the tail. Notepad++ does not do this. This is the sysadmin's daily annoyance — the deploy that fails because an editor has the log open, the `tail -f` that means leaving the GUI. It is a *daily* capability, unlike raw file size.
2. **`Ctrl+L` — collapse the file to just the matching lines, click one to jump to it in place.** With a worker thread so the filter arms immediately rather than blanking. This is the log-triage superpower, it works on a multi-GB file, and it is the one thing from the large-file story that is used every single day rather than four times a year.
3. **CSV opens as a real grid** — sticky header, click-to-sort, **Excel-style per-column value filter with type-to-search**, editable in place, two-key sorts, malformed rows marked rather than hidden, and **the file is never rewritten** (sort is a permutation over row offsets). This is EmEditor's $60/yr pitch and half of what people open Excel for, in a 1.21 MB exe, on a file too big for Excel. It is also the capability with the *least* free competition: klogg does not do this, Notepad++ does not do this without plugins, and Excel mangles your data.

The one-line positioning that follows: **"The other window. Newtpad opens the log, the CSV, the config and the scratch buffer — instantly, at any size, without locking the file."**

Supporting, not leading: the reformatters (`Ctrl+Alt+F` for JSON/XML/HTML/CSS), markdown split preview, the command palette, hot exit with session restore, per-monitor DPI v2, no telemetry, no account, one 1.21 MB exe.

### 2.3 Is "handmade, no framework, 2 MB" a purchase driver? — **No. It is a marketing asset and a credibility proxy. Lead with the effect, footnote the cause.**

This is the uncomfortable answer the brief asked for, and the evidence is fairly clean.

**Where it demonstrably works:** it is a *distribution* asset of the first order. File Pilot's [331-point Hacker News thread](https://news.ycombinator.com/item?id=43091466) was substantially about it being written in C with a custom renderer. gHacks' coverage led with "a mere 1.8 MB download" ([gHacks, 2025-02-20](https://www.ghacks.net/2025/02/20/new-file-pilot-beta-redefines-file-management-on-windows-11/)). It is why the Wookash Podcast interviewed the author at all — the same show that hosted Ryan Fleury on RAD Debugger and Sean Barrett ([Wookash Podcast](https://creators.spotify.com/pod/profile/lukasz-sciga/episodes/Design-Meets-Performance--Vjekoslav-Krajai-e31j16p)). Without the handmade story there is no Show HN, no podcast, no Handmade Network post, and therefore no press wave. On the channels that matter most to a solo developer with no audience, it is the entire ticket.

**Where it demonstrably fails:** it does not justify a price to anyone outside that circle. The How-To Geek reviewer, having praised File Pilot enough to permanently replace Explorer with it, still concluded the pricing is "definitely on the higher side" and that "only a few users may be willing to pay such a high amount for a mere file explorer." The handmade story did not buy a single dollar of price tolerance from a mainstream reviewer who had already been converted on the product.

**The mechanism.** Buyers cite *effects* — instant, doesn't lock, doesn't crash, doesn't nag — never *causes* — Odin, D3D11, no CRT, instanced quads. `demand-side-feature-research.md` §A already found this and slightly mis-framed it: it lists "instant open + tiny native exe" as "the emotional core." My read is that **the tiny exe is not the emotion, it is the evidence.** People believe "1.2 MB" the way they believe a spec sheet — it is a fast, checkable proxy for "this will not be slow, will not phone home, and will not have a 400 MB Electron runtime." The emotion is *instant*.

**The operational consequence:** the landing page headline is about what happens when you press Ctrl+O on a 4 GB log. The size, the language, the renderer and the dependency count go in a small technical strip below the fold, in the Show HN first comment, in the About box, and in a companion engineering post — where they will do far more work than they would in an H1.

### 2.4 Explicit CONFIRM / CONTRADICT against the existing corpus

**Confirms:**

- *(newtpad-research-report.md §3, "Ship-a-product realities")* — "Code signing won't stop SmartScreen false positives for a small unknown exe." **Confirmed and now stronger.** Since a March 2024 change, EV certificates no longer grant instant SmartScreen trust; reputation accrues on the file hash and on download volume regardless of certificate type, taking roughly two to eight weeks ([Microsoft Learn: SmartScreen reputation for Windows app developers](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)).
- *(newtpad-research-report.md §3)* — "No DRM/online checks: offline license key, honor-system trial." **Confirmed** as the category norm: Sublime, File Pilot and EditPad Pro all run on honour-system trials.
- *(demand-side §F)* — "Newtpad's opening: one-time purchase... undercutting the subscription treadmill." **Confirmed and strengthened** — see the contradiction on the numbers below.
- *(demand-side §B.2)* — filter-to-matching-lines as a headline large-file capability. **Confirmed as a feature decision** (it shipped, it is good, it is one of the three closing capabilities), though see the contradiction on its role in §2.1.

**Contradicts:**

1. **`demand-side-feature-research.md` §F is now factually stale on EmEditor.** The corpus states "$39.99 yr1 / $19.99 renewal." Current pricing on [emeditor.com/buy](https://www.emeditor.com/buy/) is **$60 first year, $45/yr renewal, $6/month**. The direction of the corpus's argument is right — lifetime licences did end, on 2024-08-28 ([announcement](https://www.emeditor.com/general/license-price-update-and-ending-sales-of-lifetime-licenses/)) — but the gap between Newtpad's perpetual offer and EmEditor's treadmill is now *substantially wider* than the corpus assumed. Newtpad at $49 perpetual versus EmEditor at $60/yr forever is a much better slide than $49 versus $39.99.
2. **`demand-side-feature-research.md` §F's "paid players are all moving to subscriptions" overstates the trend.** 010 Editor, EditPad Pro, Beyond Compare and File Pilot all still sell perpetual licences today. Perpetual is not a contrarian position; it is one of two live norms. Newtpad should claim it confidently but not as a unique differentiator.
3. **`demand-side-feature-research.md` §A's "Microsoft added AI to Notepad" tailwind is weakening, not strengthening.** Microsoft stripped Copilot branding from Notepad and Snipping Tool in 2026 Insider builds and committed to reducing "unnecessary Copilot entry points" starting with Notepad, Paint, Photos and Widgets ([Windows Latest, 2026-05-07](https://www.windowslatest.com/2026/05/07/windows-11-pulls-back-ai-as-microsoft-plans-to-remove-copilot-where-it-doesnt-meet-its-promise/); [Windows Central](https://www.windowscentral.com/microsoft/windows-11/microsoft-is-reevaluating-its-ai-efforts-on-windows-11-plans-to-reduce-copilot-integrations-and-evolve-recall)), and text generation moved to on-device models with **no sign-in and no subscription required** ([Windows Central](https://www.windowscentral.com/microsoft/windows-11/windows-11-notepad-will-soon-let-you-generate-text-using-on-device-ai-models-no-subscription-required)). **Do not build the launch narrative on "escape Microsoft's AI Notepad."** It was a 2025 story, the backlash worked, and by launch week the press will treat that angle as stale. Keep "no AI, no account, no telemetry" as a stated value in the product; drop it as the headline.
4. **The large-file wedge's competitive position was never assessed by the corpus.** §B.2 argues for filter-to-matches on the grounds that without it "V1 for a log user is just a fast editor that opens big files — which is what Notepad++-with-plugin already is." Correct — but the corpus does not note that **EmEditor Free** and **klogg** both give the large-file capability away at $0. That is the more important competitive fact, and it is why §2.1 demotes large files from pitch to demo.
5. **`newtpad-research-report.md` §3's implied "handmade is the story" is right about distribution and wrong about conversion.** See §2.3. The corpus never separates these, and the separation is the actionable part.

---

## 3. Channels, ranked by expected return for a solo dev with no audience and no budget

### 3.1 The ranking

| # | Channel | Realistic reach | Effort | Go / No-go |
|---|---|---|---|---|
| 1 | **Hacker News — Show HN** | 0 to ~100k, bimodal | Low (hours) | **GO — the single highest-EV action available** |
| 2 | **Windows tech press** (gHacks, XDA, How-To Geek, Neowin, BGR, MajorGeeks) | 5k–50k per outlet | Low-medium | **GO** |
| 3 | **Package managers** (Scoop, winget, Chocolatey) | Low discovery, high trust | Low, one-time | **GO — do it before launch** |
| 4 | **Handmade circuit** (Handmade Network, Wookash Podcast, Handmade Seattle, Molly Rocket community) | 1k–20k, extremely high intent | Medium, months | **GO — as a relationship, not a launch lever** |
| 5 | **SEO** ("notepad++ alternative", "large file viewer windows") | Compounding; 0 at launch | High, slow | **GO — start at launch, judge at month 9** |
| 6 | **X/Twitter build-in-public** | Near-zero from cold start; compounds | Medium, continuous | **Weak go — start now, expect nothing in week 1** |
| 7 | **Dev newsletters** (Hacker Newsletter, console.dev, TLDR) | 5k–30k | Low | **Weak go — free to submit, low hit rate** |
| 8 | **Reddit** (r/sysadmin, r/windows, r/software, r/programming) | 10k–200k if it lands | Low effort, **high ban risk** | **NO-GO for author self-posting at launch** |
| 9 | **Product Hunt** | A few hundred visits, then flat | Medium | **NO-GO** |

### 3.2 The detail

**1. Hacker News — Show HN.** The evidence is unambiguous: File Pilot's Show-HN-class submission hit **331 points and 221 comments on 2025-02-18**, and every subsequent piece of press (gHacks Feb 2025, BGR Feb 2025, How-To Geek Apr 2025, XDA Sep 2025) reads as downstream of it. Newtpad's technical story is exactly the shape HN rewards.

*Rules that will burn you.* The [Show HN guidelines](https://news.ycombinator.com/showhn.html) require "something you've made that other people can play with," "ideally without barriers such as signups or emails," and explicitly bar "blog posts, sign-up pages, newsletters, lists, and other reading material," "landing pages," and "If your work isn't ready for users to try out, please don't do a Show HN." **They do not prohibit charging money.** The two operational consequences: (a) the download must be one click, no email gate, before you post — which the unlimited trial in §1.6 delivers; (b) "Please don't ask friends to upvote or comment" is enforced, and vote-ring detection can shadowban your *domain permanently*.

*Timing.* Early velocity dominates: HN's ranking decays with time and the gravity multiplier rises, so ten upvotes in the first fifteen minutes beat fifty over six hours. Recommended window is Tuesday–Thursday, roughly 08:00–10:00 PT; a [2026 analysis of 188,000+ Show HN posts](https://danfking.github.io/blog/2026/04/23/show-hn-by-the-numbers/) puts the single best slot at Monday 00:00 UTC. Worst: Friday afternoon. Show HN volume has roughly tripled since 2019, so you are competing with ~200 posts a day.

*The thing most people get wrong:* the first two hours of comment replies matter more than the title. Block the day.

**2. Windows tech press.** gHacks, XDA, How-To Geek, BGR and Neowin all covered File Pilot inside eight months of its beta. These outlets run on "here is a fast small free thing for Windows" and will take a direct pitch — one email, one 30-second screen capture, one link. MajorGeeks and Neowin also host downloads. Effort is a few hours for the whole list. Pitch them the same week as HN so the coverage compounds rather than trickles.

**3. Package managers.** Discovery traffic is near zero; that is not why you do it. You do it because `winget install Newtpad` or `scoop install newtpad` in the Show HN thread converts the sceptic who will not run an unsigned exe from a stranger's website, and because it removes an install-friction objection permanently. Scoop is the natural home (portable, zip-based, developer tools). Paid software is acceptable in winget — File Pilot is listed as `Voidstar.FilePilot`. Manifests take days to weeks to merge, so submit in week 5, not launch week.

**4. The handmade circuit.** Small absolute numbers, but this is the exact audience that pays full price for handmade Windows tools and then evangelises them for years. The Wookash Podcast has hosted File Pilot's author, Ryan Fleury and Sean Barrett; Handmade Network hosts File Pilot's own project page. This is not a launch-week lever — it is a relationship you open in week 6 with a genuinely interesting technical artefact (the piece tree, the SEH shim over mapped reads, the wrap-indent work) and cash six months later.

**5. SEO.** The target queries are "notepad++ alternative," "large file viewer windows," "open large text file windows," "csv viewer large file windows." **I could not verify absolute search volumes — no keyword tool was available — and I am not going to guess numbers.** What *is* verifiable is durability: gHacks' [2018 gigabyte-text-files article](https://www.ghacks.net/2018/02/22/how-to-open-gigabyte-sized-text-files-on-windows/) still surfaces at the top of these searches eight years later, which is strong circumstantial evidence of persistent, non-seasonal demand that nobody has beaten with a better page. That is the opportunity: publish a genuinely better, honest, benchmark-backed page on "opening multi-GB text files on Windows" that names klogg and EmEditor fairly. Payoff is month 6–18. Start it at launch; do not expect it to matter in week one.

**6. X/Twitter.** From a cold start this returns essentially nothing in launch week. Its value is that File Pilot built its following there over three years of build-in-public clips, and those clips are what podcast hosts and journalists find. Start posting now; treat any launch-week return as a bonus.

**7. Newsletters.** Hacker Newsletter is automatic if HN lands. [console.dev](https://console.dev/) has ~30k subscribers and takes free submissions, but its [selection criteria](https://console.dev/selection-criteria) skew toward developer tools with self-service signup that "fit into the development cycle" — a native Windows text editor is a stretch. Free to submit, so submit; do not plan around it.

**8. Reddit — the trap.** The audience is right (r/sysadmin is exactly the §2.2 buyer) and the rules will eat you. Sitewide policy requires authentic participation in communities where you have a personal interest; the informal 90/10 norm is enforced unevenly and much more strictly in some subs than others; **r/programming will remove a self-promoted commercial tool**; and the catastrophic failure mode is that a **domain flagged as spam has every link to it auto-removed across all of Reddit, which is close to irreversible**. r/sysadmin is specifically characterised as a harder, higher-value community to approach only after establishing account history. *Do not post Newtpad to Reddit yourself in launch week.* Let the HN and press wave get organically cross-posted by others, and separately — starting now, not in October — participate honestly and with disclosure in the existing "what do you use for huge logs" threads.

**9. Product Hunt — skip it.** Wrong audience (SaaS and no-code, not native Windows exes) and demonstrably declining returns for indie technical launches: typical indie launches report a few hundred visitors and then a flat line, the ranking system punishes anyone without a pre-existing audience in the first hour, and multiple 2026 write-ups conclude PH is now a net negative as a primary channel for technical founders ([Puthusu](https://www.puthusu.com/blog/is-product-hunt-worth-it), [Launchedly](https://launchedly.app/blog/why-product-hunt-killed-indie-makers)). If you launch there at all, do it the same day as HN, spend zero additional effort, and expect nothing.

### 3.3 File Pilot's actual growth path — the case study

Reconstructed from primary sources, this is the template:

1. **Feb 2022 – Jan 2025: three years of building in public** on Handmade Network and X, posting feature clips (tabs Nov 2022, batch rename Nov 2022, drag-and-drop Apr 2024, previews Oct 2024). Free public beta throughout. No monetisation.
2. **2025-02-18: the Hacker News detonation** — 331 points, 221 comments.
3. **Feb–Sep 2025: the press wave follows** — gHacks (2025-02-20), BGR (Feb 2025), How-To Geek (Apr 2025), XDA (Sep 2025), Windows Forum threads throughout.
4. **Throughout: the handmade-circuit long tail** — the BSC 2025 engine talk, the Wookash Podcast interview, the Hanselminutes interview, a code-walkthrough stream. Each one is a durable artefact that keeps generating discovery.
5. **Only then: pricing published**, perpetual, with a 20% early-bird, and the free beta left up.

**Two lessons Newtpad should take literally.** First, **the free public beta ran for years before any price existed** — the audience was built while the product was free, and the paywall arrived after the goodwill. Newtpad cannot replicate three years, but it can and should ship a signed public beta *weeks* before launch, which happens to also be what solves the SmartScreen reputation problem (§4). Second, **step 4 is what makes step 2 repeatable.** File Pilot has had a second, third and fourth wave because the author produced technical artefacts worth covering. Newtpad's equivalents already exist in the tree: the piece tree, the SEH-shimmed mapped reads, the glyph atlas, the wrap-indent work. Write them up.

---

## 4. Launch sequence

**Today: Tuesday 2026-08-04. Launch day: Tuesday 2026-10-06 (week 9).** Tuesday chosen for the Show HN window; nine weeks chosen because the SmartScreen reputation clock (two to eight weeks of real download volume) is the longest pole and it cannot be shortened with money.

### 4.1 The three hard blockers before you can charge money

**Blocker 1 — Code signing, and the reputation clock.**

- **Recommended: Azure Artifact Signing (formerly Trusted Signing) — $9.99/month Basic** (up to 5,000 signatures, $0.005 each thereafter); Premium is $99.99/month ([Azure Artifact Signing](https://azure.microsoft.com/en-us/products/artifact-signing)). It reached GA in 2026 and is **now open to self-employed individuals** — the previous three-years-of-business-history requirement was dropped — for US, Canadian, EU and UK businesses and self-employed individuals, with identity validation through Microsoft Entra Verified ID ([Microsoft Community Hub](https://techcommunity.microsoft.com/blog/microsoft-security-blog/trusted-signing-is-now-open-for-individual-developers-to-sign-up-in-public-previ/4273554)). **Real cost: ~$120/year.**
  - ⚠️ **Unverified risk, budget for it:** at least one developer reports on [Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/5595324/i-signed-up-to-generate-certificates-to-sign-my-co) being unable to create the required role assignment without a Microsoft Entra ID P2 or Entra ID Governance licence, at extra cost. I could not confirm whether this is still true at GA. **Start this in week 0, not week 6** — if it turns out to be blocked, you need the fallback lead time.
- **Fallback: a conventional OV certificate**, roughly $219–$400/year ([SSL Dragon](https://www.ssldragon.com/ssl-certificates/code-signing/); DigiCert quoted at $400 OV / $685 EV). Since 2023-06-01 the CA/Browser Forum requires the private key to live on FIPS 140-2 Level 2 hardware — no more downloadable `.pfx` — so the CA ships you a USB token, adding shipping delay. Note also that as of 2026-03-01 maximum certificate validity dropped to 460 days.
- **The part money does not fix.** Since a March 2024 change, **EV no longer grants instant SmartScreen trust**; reputation accrues by file hash and download volume regardless of certificate type, and a newly built binary starts at zero reputation on **every release** ([Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)). Reported time to clear: two to eight weeks with real download volume. **This is the reason the calendar below ships a signed public beta in week 1.** It directly confirms the corpus's "worst money ever spent" note — signing is table stakes for not being blocked outright, and does nothing for you on day one.

**Blocker 2 — Payment and licensing provider. Recommendation: Paddle.**

| Provider | Fee | Merchant of record? | EU VAT | Verdict |
|---|---|---|---|---|
| **Paddle** | **5% + 50¢** per checkout transaction | **Yes** | Full registration, filing and remittance | **Recommended.** Cheapest true MoR; File Pilot uses it; requires account verification, so start early |
| Lemon Squeezy | 5% + 50¢ historically | Yes | Yes | **Avoid for a new seller.** Acquired by Stripe (Jul 2024) and being folded into Stripe Managed Payments; onboarding has reportedly slowed to weeks, and the long-term direction is migration off it |
| Stripe Managed Payments | **3.5% MoR surcharge on top of 2.9% + 30¢ = ~6.4% + 30¢** domestic; higher on international cards | Yes | Yes | Viable but ~28% more expensive than Paddle on every sale |
| Stripe (plain) | 2.9% + 30¢ | **No** | **You own EU VAT registration and filing** | **No.** A solo developer selling to EU consumers without an MoR is signing up for OSS/MOSS registration and quarterly returns |
| Gumroad | **10% + 50¢** plus card processing → ~12.9% + 80¢ effective; payout threshold raised to $100 in March 2026 | Yes (MoR since Jan 2025) | Yes | **No.** Roughly 2.5× Paddle's take |

Sources: [paddle.com/pricing](https://www.paddle.com/pricing) · [stripe.com/managed-payments](https://stripe.com/managed-payments) · [lemonsqueezy.com/blog/2026-update](https://www.lemonsqueezy.com/blog/2026-update) · [Gumroad fee analyses, 2026](https://checkoutpage.com/blog/how-gumroad-pricing-works-and-a-cheaper-alternative)

At $44 average, Paddle nets ~$41.30/sale versus ~$40.80 for Stripe Managed Payments and ~$37.60 for Gumroad. The fee difference is real but secondary; **the deciding factor is that Paddle is a mature MoR that will not be migrated out from under you mid-launch.**

**Blocker 3 — Newtpad has no licensing code, and its installer has never been run.**

This is the blocker most likely to be underestimated, because it is product work, not paperwork.

- Per [features.md](../../../../../../../E:/Code/Newtpad/docs/features.md), Newtpad has exactly **one** network call in the entire product (the GitHub update check) and **no concept of a licence at all**. Offline key validation, a trial state that survives reinstall without being creepy, and a non-blocking reminder are all net-new code that has to respect "no telemetry, no background traffic, no timers."
- features.md line 53 states plainly of the Inno Setup installer: ***"Not verified: the installer has never been compiled or run."*** You cannot charge money for a product whose installer is unverified. Compile it, run it on a clean Windows VM, and verify per-user HKCU/`%LOCALAPPDATA%` behaviour with no elevation.
- Also on the launch-blocker list from features.md's own admissions: the two **documented dead palette commands** (*Extend Column Selection Left / Right* "appear in the palette but do nothing"). A paying customer finding a dead menu item in the first week is a refund and a review.

**Cost summary:** signing ~$120/yr (or $219–$400/yr fallback) · Paddle 5% + 50¢, $0 fixed · domain + static hosting ~$20–60/yr · **total fixed cash cost to be able to charge money: roughly $150–$500 for year one.** The expensive input is time, not money.

### 4.2 The dated checklist

**Week 0 — 2026-08-04 to 08-10 · Decisions and long-lead paperwork**
- [ ] Lock price and licence terms (§1.4). Write the licence text and the refund policy (copy EditPad Pro's 3-month unconditional guarantee — it is a conversion asset and costs almost nothing against an honour-system product).
- [ ] **Start Azure Artifact Signing identity validation today.** It is the longest lead item and has an unverified Entra P2 risk. If it stalls by week 2, order an OV cert with hardware token as the fallback.
- [ ] Register the domain; sort the business/tax entity if not already done (Paddle verification will ask).
- [ ] Decide the trial mechanism: unlimited, fully functional, periodic non-blocking reminder. No time bomb, no feature gate, no phone-home.

**Week 1 — 08-11 to 08-17 · Signing live, beta in the wild**
- [ ] Sign every build from now on. Wire signing into `build.bat release`.
- [ ] **Compile and actually run the Inno Setup installer** on a clean Windows VM. This closes the features.md line-53 gap.
- [ ] Publish a **signed public beta** on GitHub Releases, publicly linked. **This starts the SmartScreen reputation clock — it is why this week, not week 7.**
- [ ] Start posting build clips on X. Zero expectations, pure compounding.

**Week 2 — 08-18 to 08-24 · Money plumbing**
- [ ] Create and verify the Paddle account (verification takes real time).
- [ ] Implement offline licence key generation and validation. No activation server.
- [ ] Wire purchase → key email → download. Test with a real card on a real transaction.

**Week 3 — 08-25 to 08-31 · Landing page**
- [ ] One page, static host. Above the fold: a **single looping capture of a multi-GB log opening instantly, then `Ctrl+L` collapsing it to matches**. Headline is the effect, not the implementation.
- [ ] Below: the three closing capabilities (§2.2), then price, then a small technical strip (1.2 MB, Odin, D3D11, no telemetry, no account, 14-ish OS DLLs).
- [ ] Download button with **no email gate** — required by Show HN's rules and by the trial model.
- [ ] Honest comparison table naming Notepad++, EmEditor, klogg and VS Code, including where they win. Credibility is the scarce resource.

**Week 4 — 09-01 to 09-07 · Close the launch-blocking defects**
- [ ] Fix or hide the two dead palette commands (*Extend Column Selection Left / Right*).
- [ ] Sweep `docs/reported-bugs.md` for anything a first-week paying user would hit.
- [ ] Ship the `.py` lexer, or explicitly document the gap on the site rather than letting a buyer discover it.
- [ ] Write the docs page — keyboard reference, the `keys.txt` / `rules.txt` / `.theme` story, the large-file caveats stated honestly (mapping is local-fixed-drives only; 64 tabs restored; 100k match cap; 100k-row CSV sort ceiling).

**Week 5 — 09-08 to 09-14 · Distribution plumbing + real users**
- [ ] Submit Scoop, winget and Chocolatey manifests. **They take days to weeks to merge — this is why it is week 5.**
- [ ] Ship beta build #2. Every release resets file-hash reputation, so keep the cadence up and keep download volume flowing.
- [ ] Recruit 10–20 real users (sysadmin friends, the Handmade Discord, a Newtpad-relevant thread you already participate in). You need testimonials and you need download volume for SmartScreen.

**Week 6 — 09-15 to 09-21 · Press kit and the technical artefact**
- [ ] Press kit: five screenshots, a 30-second capture, a one-paragraph pitch, price, contact. One page, one zip.
- [ ] Write the **engineering post** — the piece tree over mmap plus SEH-shimmed reads, or the glyph atlas, or how filter-view stays responsive on a 4 GB file. This is the artefact that gets you the Wookash/Handmade Network interest and gives HN something to argue about.
- [ ] Draft the Show HN title (plain and factual, no adjectives) and the first comment (what it is, what it cannot do, why you built it, what it costs).
- [ ] Post the project on Handmade Network.

**Week 7 — 09-22 to 09-28 · Dry run and embargo pitches**
- [ ] **Buy your own licence from a clean Windows VM on a clean network.** Verify: SmartScreen behaviour, checkout, key delivery, key validation, the VAT invoice, and the refund path end to end.
- [ ] Email gHacks, XDA, How-To Geek, Neowin, BGR and MajorGeeks with the press kit and a launch date. Offer them the build now under an informal embargo — some will want lead time.
- [ ] Submit to console.dev.

**Week 8 — 09-29 to 10-05 · Freeze**
- [ ] Code freeze. Release candidate signed and pushed a few days early so its hash has *some* reputation before launch day.
- [ ] Final SmartScreen check on three genuinely clean machines.
- [ ] Confirm the landing page is static and will survive a front-page spike.
- [ ] Clear the calendar for 10-06 and 10-07.

**Week 9 — LAUNCH · Tuesday 2026-10-06**
- 08:30 PT — **post the Show HN.** Plain title. First comment already written.
- 08:30–16:00 PT — **do nothing but answer comments.** This is the whole job. Early velocity decides everything, and the reply quality is what converts sceptics.
- Same day — send the press emails, post on X, post on Handmade Network, post to Product Hunt if it costs you five minutes.
- **Do not post to Reddit.** (§3.2 item 8.)

**Weeks 9–12 — 10-06 to 11-02 · Ride it**
- [ ] Ship a patch release within 5–7 days addressing the loudest launch-week complaint. Nothing signals "this is alive and worth $49" like that.
- [ ] Follow up with any outlet that did not respond — the second email after a 300-point HN thread lands very differently.
- [ ] Log every objection verbatim. The launch-week objection list is the most valuable roadmap input you will ever get.
- [ ] Open the podcast/YouTube conversations now that there is a result to point at.

**Week 13+ — from 11-03 · Compounding**
- [ ] Publish the SEO pages: "opening multi-GB text files on Windows," "Notepad++ alternatives, honestly compared."
- [ ] Begin genuine, disclosed participation in the relevant Reddit threads.
- [ ] Decide at month 6 whether the intro price stays retired at $49 and whether a lifetime tier makes sense at v1.5.

### 4.3 What to measure

Instrument the *website*, not the app — the product's no-telemetry promise is a positioning asset (`demand-side` §D) and must not be broken for analytics.

**Funnel:** unique landing-page visits → download rate → **trial-to-purchase conversion** (the number that decides whether the price or the product is wrong) → refund rate (>5% means the landing page is overselling).

**Attribution:** UTM every outbound link. The whole point is learning which of the nine channels in §3 actually paid, so the next launch is not a coin flip.

**Two that people forget:**
- **Median days from download to purchase.** With an unlimited honour-system trial this can be weeks. If you judge conversion on day 3 you will panic and discount.
- **SmartScreen block reports.** Ask on the download page ("did Windows warn you? tell me"). It is the one launch-killer you cannot see from your own machine.

**Qualitative, and most important:** the top five verbatim objections from the HN thread and from support email. That list is worth more than every number above.

---

## 5. Sources

[sublimehq.com/store/text](https://sublimehq.com/store/text) · [emeditor.com/buy](https://www.emeditor.com/buy/) · [emeditor.com — ending lifetime licenses](https://www.emeditor.com/general/license-price-update-and-ending-sales-of-lifetime-licenses/) · [emeditor.com — lifetime price update 2019](https://www.emeditor.com/general/lifetime-license-price-update/) · [emeditor.com — large file support](https://www.emeditor.com/text-editor-features/large-file-support/optimized-sort/) · [en.wikipedia.org/wiki/EmEditor](https://en.wikipedia.org/wiki/EmEditor) · [sweetscape.com/store](https://www.sweetscape.com/store/) · [editpadpro.com/buynow.html](https://www.editpadpro.com/buynow.html) · [ultraedit.com/pricing](https://www.ultraedit.com/pricing/) · [capterra.com — UltraEdit](https://www.capterra.com/p/183163/UltraEdit/) · [componentsource.com — UltraEdit prices](https://www.componentsource.com/product/ultraedit/prices) · [componentsource.com — Beyond Compare prices](https://www.componentsource.com/product/beyond-compare/prices) · [filepilot.tech/pricing](https://filepilot.tech/pricing) · [filepilot.handmade.network](https://filepilot.handmade.network/) · [notepad-plus-plus.org/donate](https://notepad-plus-plus.org/donate/) · [github.com/rizonesoft/Notepad3](https://github.com/rizonesoft/Notepad3) · [flos-freeware.ch](https://www.flos-freeware.ch/) · [news.ycombinator.com/item?id=43091466](https://news.ycombinator.com/item?id=43091466) · [news.ycombinator.com/showhn.html](https://news.ycombinator.com/showhn.html) · [news.ycombinator.com/item?id=24303287](https://news.ycombinator.com/item?id=24303287) · [news.ycombinator.com/item?id=37220397](https://news.ycombinator.com/item?id=37220397) · [community.notepad-plus-plus.org — max file size thread](https://community.notepad-plus-plus.org/topic/25955/i-hate-notepad-because-the-maximum-file-size-it-lets-me-open-is-only) · [api.github.com/repos/variar/klogg](https://api.github.com/repos/variar/klogg) · [ghacks.net — gigabyte text files (2018)](https://www.ghacks.net/2018/02/22/how-to-open-gigabyte-sized-text-files-on-windows/) · [ghacks.net — File Pilot beta (2025)](https://www.ghacks.net/2025/02/20/new-file-pilot-beta-redefines-file-management-on-windows-11/) · [howtogeek.com — File Pilot review](https://www.howtogeek.com/third-party-file-manager-impressive-replaced-windows-file-explorer/) · [xda-developers.com — File Pilot](https://www.xda-developers.com/file-pilot-is-best-windows-explorer-alternative/) · [learn.microsoft.com — SmartScreen reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation) · [azure.microsoft.com — Artifact Signing](https://azure.microsoft.com/en-us/products/artifact-signing) · [techcommunity.microsoft.com — Trusted Signing for individuals](https://techcommunity.microsoft.com/blog/microsoft-security-blog/trusted-signing-is-now-open-for-individual-developers-to-sign-up-in-public-previ/4273554) · [learn.microsoft.com — Q&A on Entra P2 requirement](https://learn.microsoft.com/en-us/answers/questions/5595324/i-signed-up-to-generate-certificates-to-sign-my-co) · [ssldragon.com — code signing prices](https://www.ssldragon.com/ssl-certificates/code-signing/) · [paddle.com/pricing](https://www.paddle.com/pricing) · [stripe.com/managed-payments](https://stripe.com/managed-payments) · [lemonsqueezy.com/blog/2026-update](https://www.lemonsqueezy.com/blog/2026-update) · [checkoutpage.com — Gumroad pricing](https://checkoutpage.com/blog/how-gumroad-pricing-works-and-a-cheaper-alternative) · [danfking.github.io — Show HN by the numbers](https://danfking.github.io/blog/2026/04/23/show-hn-by-the-numbers/) · [console.dev/selection-criteria](https://console.dev/selection-criteria) · [puthusu.com — is Product Hunt worth it](https://www.puthusu.com/blog/is-product-hunt-worth-it) · [launchedly.app — Product Hunt and indie makers](https://launchedly.app/blog/why-product-hunt-killed-indie-makers) · [redship.io — Reddit self-promotion rules 2026](https://redship.io/blog/reddit-self-promotion-rules-2026) · [windowslatest.com — Windows 11 pulls back AI](https://www.windowslatest.com/2026/05/07/windows-11-pulls-back-ai-as-microsoft-plans-to-remove-copilot-where-it-doesnt-meet-its-promise/) · [windowscentral.com — Notepad on-device AI, no subscription](https://www.windowscentral.com/microsoft/windows-11/windows-11-notepad-will-soon-let-you-generate-text-using-on-device-ai-models-no-subscription-required) · [creators.spotify.com — Wookash Podcast, Vjekoslav Krajačić](https://creators.spotify.com/pod/profile/lukasz-sciga/episodes/Design-Meets-Performance--Vjekoslav-Krajai-e31j16p)

**Explicitly unverified in this report:** Sublime HQ and IDM headcounts; File Pilot's regular (non-early-bird) prices (client-side rendered; corroborated only through third-party reviews); absolute SEO search volumes; whether Azure Artifact Signing still requires an Entra ID P2 licence for role assignment at GA; all revenue scenarios in §1.5.
