name: GitHub Actions Real-time Log Shipper

This project demonstrates a method for streaming GitHub Actions workflow logs in near real-time to an external HTTP server, such as a Rails application. This is particularly useful for building custom dashboards or UIs where developers might not have direct access to GitHub's native workflow logs.

## How it Works

The solution employs a two-workflow (sidecar) pattern:

1.  **`poc.yaml` (CI Worker):** This is your primary workflow where your actual CI/CD steps (build, test, deploy, etc.) reside. It's designed to simulate a long-running job with various output.
2.  **`log-shipper.yaml` (Real-time Log Shipper):** This workflow is triggered whenever the `CI Worker` workflow starts. Its sole purpose is to poll the `CI Worker`'s logs using the GitHub CLI (`gh run view --log`) and send them to your configured HTTP server.

This approach ensures:
*   **Real-time Updates:** Logs are sent periodically (e.g., every 15 seconds) as the `CI Worker` progresses.
*   **Complete Logs:** Each update sends the full log content up to that point, ensuring no data is missed.
*   **Decoupling:** The log shipping mechanism is separate from your core CI/CD logic.
*   **API Quota Management:** The polling interval can be adjusted to manage GitHub API usage.

## Project Setup

### 1. GitHub Actions Workflows

Ensure you have the following files in your `.github/workflows/` directory:

#### `.github/workflows/poc.yaml` (CI Worker)

This workflow simulates a typical CI job.

```yaml
name: CI Worker
on:
  push:
    branches:
      - main
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Simulate a multi-step build process
        run: |
          echo "Starting the build process..."
          echo "---------------------------------"
          
          echo "Step 1: Installing dependencies..."
          sleep 5
          echo "Dependencies installed."
          echo "---------------------------------"

          echo "Step 2: Running tests..."
          for i in {1..5};
            echo "Running test $i..."
            sleep 2
          done
          echo "All tests passed."
          echo "---------------------------------"

          echo "Step 3: Building the application..."
          sleep 5
          echo "Build complete."
          echo "---------------------------------"

          echo "Worker job is now complete."
```

#### `.github/workflows/log-shipper.yaml` (Real-time Log Shipper)

This workflow watches and ships the logs.

```yaml
name: Real-time Log Shipper
on:
  workflow_run:
    workflows: ["CI Worker"] # Triggered by the workflow named "CI Worker"
    types:
      - requested # Trigger as soon as the CI Worker is requested to run

permissions:
  actions: read # Required to read workflow run details and logs

jobs:
  log-shipper:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3 # Required for 'gh' CLI to find repo context

      - name: Get Build Job ID
        id: get_job_id
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          RUN_ID: ${{ github.event.workflow_run.id }}
        run: |
          # Find the specific ID for the 'build' job within the triggering workflow run.
          # This assumes your CI Worker has a job named 'build'.
          BUILD_JOB_ID=$(gh run view $RUN_ID --json jobs -q '.jobs[] | select(.name == "build") | .id')
          echo "build_job_id=$BUILD_JOB_ID" >> $GITHUB_OUTPUT

      - name: Stream Logs to HTTP Server
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          BUILD_JOB_ID: ${{ steps.get_job_id.outputs.build_job_id }}
        run: |
          echo "Found build job ID: $BUILD_JOB_ID"
          echo "Starting to poll for logs..."

          # Poll for logs every 15 seconds while the job is in progress.
          # The `gh` CLI is pre-installed on GitHub-hosted runners.
          while gh run view $BUILD_JOB_ID --json status -q '.status' | grep -q 'in_progress'; do
            echo "Job is in progress. Fetching latest logs..."
            # Send the full log content with a custom header for job identification.
            gh run view $BUILD_JOB_ID --log | curl -X POST -H "X-GitHub-Job-ID: $BUILD_JOB_ID" -d @- http://your-log-server.com/logs
            sleep 15 # Adjust this value to control polling frequency and API usage.
          done

          # The job is finished. Send the final, complete log one last time.
          echo "Job has finished. Sending final complete log..."
          gh run view $BUILD_JOB_ID --log | curl -X POST -H "X-GitHub-Job-ID: $BUILD_JOB_ID" -d @- http://your-log-server.com/logs
          echo "Log shipping complete."
```

**Important Notes:**

*   Replace `http://your-log-server.com/logs` with the actual URL of your log receiving endpoint.
*   Ensure your repository's default branch is `main` (or adjust the `on: push: branches:` in `poc.yaml` accordingly).
*   The `GITHUB_TOKEN` in `log-shipper.yaml` automatically gets the necessary permissions due to the `permissions: actions: read` block.

### 2. Rails Application Setup (Log Receiver)

This section outlines the basic Rails components needed to receive and store the logs.

#### 1. Database Migration

Create a migration to set up your `log_entries` table.

```bash
rails generate migration CreateLogEntries job_id:string:uniq content:text
```

Modify the generated migration file (`db/migrate/YYYYMMDDHHMMSS_create_log_entries.rb`):

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_log_entries.rb
class CreateLogEntries < ActiveRecord::Migration[7.0]
  def change
    create_table :log_entries do |t|
      t.string :job_id, null: false, index: { unique: true } # Unique ID from GitHub Actions
      t.text :content # The full log content

      t.timestamps # created_at and updated_at
    end
  end
end
```

Run the migration:

```bash
rails db:migrate
```

#### 2. Database Model

Create the `LogEntry` model to interact with the `log_entries` table.

```ruby
# app/models/log_entry.rb
class LogEntry < ApplicationRecord
  validates :job_id, presence: true, uniqueness: true
end
```

#### 3. Controller

Create a controller to handle incoming log data.

```ruby
# app/controllers/logs_controller.rb
class LogsController < ApplicationController
  # Disable CSRF token verification for this specific endpoint
  # as it's an API endpoint receiving data from GitHub Actions.
  skip_before_action :verify_authenticity_token, only: [:create]

  def create
    job_id = request.headers['X-GitHub-Job-ID'] # Get the unique job ID from the custom header
    log_content = request.body.read # Read the raw log content from the request body

    if job_id.blank?
      render json: { error: 'X-GitHub-Job-ID header is missing' }, status: :bad_request
      return
    end

    # Find an existing log entry by job_id or initialize a new one.
    # This ensures that subsequent updates for the same job_id overwrite the content.
    log_entry = LogEntry.find_or_initialize_by(job_id: job_id)
    log_entry.content = log_content

    if log_entry.save
      render json: { message: 'Log received and updated successfully', job_id: job_id }, status: :ok
    else
      render json: { errors: log_entry.errors.full_messages }, status: :unprocessable_entity
    end
  rescue => e
    # Log the error for debugging purposes
    Rails.logger.error "Error processing log: #{e.message}"
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end
end
```

#### 4. Routes

Define the route for your log receiving endpoint.

```ruby
# config/routes.rb
Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Route for receiving logs from GitHub Actions
  post '/logs', to: 'logs#create'

  # Other routes...
end
```

## Running the Rails Application

To run your Rails application locally (for testing):

```bash
rails s
```

Ensure your Rails application is accessible from the internet if you are deploying your GitHub Actions workflows to a public repository. For local testing, you might use a tool like `ngrok` to expose your local server to the internet.

## Viewing Logs

Once logs are being sent to your Rails application, you can retrieve them by querying your database or by creating a simple API endpoint in your Rails app to fetch `LogEntry` records by `job_id`. Your UI can then poll this endpoint or use WebSockets for real-time display.

```