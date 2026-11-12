# Bahar Foods

Daily lunch menu and delivery for Bahar Foods, бул. Прага 6.

- **Customers** see today's menu, order for delivery to home or office, or call 0896 687878.
- **Staff** open the site with `#admin` at the end of the address and sign in.

## Staff area (`/#admin`)
- **Меню** — pick today (or tomorrow the evening before) and switch dishes on and off. New dish: **+ Ново ястие**.
- **Снимка** — the picture for the Viber channel, made from the dishes that are on. **Както досега** is the
  familiar landscape menu; **За телефон** is a tall version. On a phone, **Изпрати във Viber** opens sharing.
- **Поръчки** — new orders arrive within 20 seconds (press **Звук** once for a beep). Kitchen totals, cars,
  a copyable list for each driver, statuses, cancel with a reason, and **+ Поръчка по телефона**.
- **Настройки** — name, phone, address, hours, order cut-off, delivery times, fee, cars, categories, logo
  and the photo on the menu picture.

Online orders stop at the cut-off (14:30 by default) and the site shows the phone number instead.
If no day is picked, the site says the menu is coming soon and takes no orders.

## How it's built
`public/index.html` is the whole site, hosted on Cloudflare (Worker `baharfoods`, see `wrangler.jsonc`) from this repo. The data lives in Supabase; every
database change is in `supabase/migrations`. Changes are made by asking Claude: see `CLAUDE.md`.
