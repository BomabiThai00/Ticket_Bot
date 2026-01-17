# TicketBot

**TicketBot** is an autonomous, intelligent support assistant designed to alleviate the "context load" on support engineers. It acts as a middleware between your CRM (specifically **Zoho Desk**) and Large Language Models (**Azure OpenAI**), automatically analyzing ticket conversations to provide concise summaries, Root Cause Analysis (RCA), and actionable next steps.

## 🚀 Key Features

* **Intelligent Summarization:** utilizing Azure OpenAI (GPT-4) to read ticket history and generate a structured summary including a chronological timeline, root cause categorization, and suggested next steps.
* **Automated RCA:** Classifies issues into defined categories (e.g., *Software Bug*, *User Error*, *Network/Infrastructure*) to standardize reporting.
* **Incremental Processing:** Uses a local SQLite database to track processed tickets. It only re-analyzes a ticket if sufficient new data (default: 5+ new messages) has accumulated, saving API costs and reducing noise.
* **Privacy First (PII Redaction):** Includes a robust `PiiSanitizer` service that scrubs sensitive data—Emails, Phone Numbers, IPv4 addresses, JWT Tokens, and SIP URIs—before any text leaves your infrastructure.
* **Concurrency:** Built with a `FixedThreadPool` (default: 1 worker) to handle network-heavy fetching and processing asynchronously without blocking the main execution loop.
* **Resilient Networking:** Implements exponential backoff retries for database locks and API timeouts. Handles OAuth 2.0 token rotation automatically for Zoho Desk.
* **Auto-Configuration:** On the first run, the bot automatically detects your Zoho Organization ID, the "Open Cases" view ID, and your Agent ID to ensure it only processes relevant tickets.

---

## 🛠️ Architecture Components

The application is structured into modular services:

* **Engine (`lib/ticket_bot/engine.rb`):** The orchestrator. It manages the main event loop, thread pool, and dispatching of tickets to the analyzer.
* **Clients:**
* `ZohoClient`: Handles all interactions with Zoho Desk API (fetching tickets, threads, posting comments).
* `LlmClient`: Manages authentication and request formatting for Azure OpenAI.


* **Core Services:**
* `Tracker`: An SQLite-backed state manager (WAL mode enabled) to ensure atomic, ACID-compliant tracking of processed tickets.
* `Authenticator`: Manages Zoho OAuth 2.0 lifecycles, automatically refreshing access tokens when expired and updating the `.env` file.
* `ThreadAnalyzer`: The "brain" that prepares prompts, manages context windows, and parses the LLM's JSON response.


* **Utilities:**
* `PiiSanitizer`: Regex-based cleaning of sensitive text.
* `Logger`: Multi-IO logging to both `STDOUT` and `logs/bot.log`.



---

## ⚙️ Setup & Installation

### 1. Prerequisites

* Ruby 3.0+
* SQLite3

### 2. Installation

Clone the repository and install dependencies:

```bash
git clone <repository-url>
cd ticket_bot
bundle install

```

### 3. Environment Configuration

Create a `.env` file in the root directory. You must provide credentials for both Zoho Desk and Azure OpenAI.

```bash
# .env

# --- Zoho Desk OAuth ---
ZOHO_CLIENT_ID=your_zoho_client_id
ZOHO_CLIENT_SECRET=your_zoho_client_secret
ZOHO_REFRESH_TOKEN=your_zoho_refresh_token
ZOHO_ACCESS_TOKEN=   # Optional: Will be auto-filled by the bot
ZOHO_TOKEN_EXPIRY=   # Optional: Will be auto-filled by the bot

# --- Azure OpenAI ---
AZURE_TENANT_ID=your_azure_tenant_id
AZURE_CLIENT_ID=your_azure_client_id
AZURE_CLIENT_SECRET=your_azure_client_secret

# --- Platform Select ---
PLATFORM=zoho  # Default. Set to 'hubspot' if using HubspotClient logic.

```

### 4. Application Configuration

The bot uses a `settings.yml` file to store persistent runtime configurations (Org ID, View ID, Agent ID).

* **Location:** `ticket_bot/settings.yml`
* **Auto-Detection:** You do **not** need to create this manually. The `Engine` will automatically fetch your Organization, find the "Open Cases" view, and identify your Agent ID upon the first successful run.

---

## 🖥️ Usage

To start the bot, run the executable script from the root directory:

```bash
./bin/start_bot

```

**What happens next?**

1. **Bootstrapping:** The bot verifies connection to Zoho and Azure. It auto-detects your Agent ID and View ID if not already set.
2. **Polling:** It fetches tickets from the "Open Cases" view every 60 seconds.
3. **Filtering:** It processes **only** tickets assigned to you (the authenticated agent) and skips tickets with statuses "On Hold" or "Closed".
4. **Analysis:**
* Checks the local DB: *Has this ticket been updated significantly since the last scan?*
* If **Yes**: Fetches threads -> Scrubs PII -> Sends to Azure -> Posts a Private Note -> Updates DB.
* If **No**: Skips to save resources.



---

## 🛡️ Error Handling & Resilience

TicketBot is designed to be self-healing:

* **Database Locking:** If the SQLite database is busy (concurrent writes), the `Tracker` implements a retry mechanism with exponential backoff and jitter.
* **Token Expiry:** The `Authenticator` checks token validity before every request. If expired, it hits the Zoho OAuth endpoint, refreshes the token, and writes the new values back to your `.env` file immediately.
* **API Failures:** The `ZohoClient` includes retry logic for timeouts (`Faraday::TimeoutError`) and server errors, pausing execution briefly between attempts.
* **LLM Stability:** If Azure returns a non-200 status or invalid JSON, the bot logs the error and gracefully skips posting for that specific ticket, preventing garbage data from entering your ticketing system.

---

## 🔒 Data Privacy

The `PiiSanitizer` module ensures strict data hygiene before external AI processing. The following patterns are redacted:

* **Email Addresses:** Replaced with `[EMAIL]`
* **Phone Numbers:** Replaced with `[PHONE]`
* **IPv4 Addresses:** Replaced with `[IP_ADDR]`
* **JWT Tokens:** Replaced with `[AUTH_TOKEN_REDACTED]`
* **SIP URIs:** Replaced with `[SIP_URI]`
* **URL Parameters:** Stripped to remove potential secrets in query strings.