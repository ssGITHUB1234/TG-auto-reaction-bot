# TG-auto-reaction-bot (Supabase backend)

This version uses Supabase (Postgres) as the backend instead of SQLite.

Quick overview
- Use Supabase to store bots, bot users, and broadcasts.
- Admin and user dashboards remain as static pages.
- ADMIN_PASSWORD still used for simple admin authentication.
- Long-polling Telegraf bots are launched inside the server process.

Setup (Supabase)
1. Create a Supabase project at https://app.supabase.com/.
2. Go to the SQL Editor and run the SQL in `migrations/init.sql` to create the tables.
3. In Project Settings → API, copy:
   - SUPABASE_URL (the project URL)
   - SUPABASE_KEY (service_role key or anon key — for server usage use service_role if needed; store it securely)
4. Set environment variables:
   - SUPABASE_URL
   - SUPABASE_KEY
   - ADMIN_PASSWORD
   - PORT (optional)

Local run
1. Copy `.env.example` to `.env` and fill values.
2. npm install
3. npm start
4. Visit:
   - http://localhost:3000/index.html (user)
   - http://localhost:3000/admin.html (admin)

Render deployment
- Add SUPABASE_URL and SUPABASE_KEY as environment variables in Render.
- Add ADMIN_PASSWORD env var.
- Build command: `npm install`
- Start command: `node server.js`

Important notes & security
- Use a secure SUPABASE_KEY (do not expose in client-side code). When deploying, only the server uses the key.
- Consider Row Level Security (RLS) and policies in Supabase if you later expose APIs that might be called by clients directly.
- For production, avoid storing bot tokens in plaintext if possible — consider encryption or a secrets manager.
