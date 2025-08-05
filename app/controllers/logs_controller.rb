require 'openssl'

# app/controllers/logs_controller.rb
class LogsController < ApplicationController
  # CRITICAL SECURITY NOTE:
  # We are skipping CSRF token verification for this endpoint (`create`).
  # This is acceptable ONLY because we are implementing a robust signature
  # verification mechanism (HMAC-SHA256) to authenticate the source of the request.
  # WITHOUT THIS SIGNATURE VERIFICATION, this endpoint would be highly vulnerable
  # to Cross-Site Request Forgery (CSRF) attacks, allowing any service to send data.
  skip_before_action :verify_authenticity_token, only: [:create]

  # Ensure the secret is loaded from environment variables (e.g., Rails credentials, .env file)
  LOG_SECRET = ENV['LOG_SECRET']

  before_action :verify_signature, only: [:create]

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

  private

  def verify_signature
    unless LOG_SECRET.present?
      Rails.logger.error "LOG_SECRET environment variable is not set."
      render json: { error: 'Server configuration error: LOG_SECRET is missing.' }, status: :internal_server_error
      return
    end

    signature_header = request.headers['X-Hub-Signature-256']
    unless signature_header.present?
      render json: { error: 'X-Hub-Signature-256 header is missing' }, status: :unauthorized
      return
    end

    # Extract the signature part (remove 'sha256=')
    signature = signature_header.split('=').last

    # Read the raw request body for signature verification
    request.body.rewind # Rewind the body stream to read it again
    payload_body = request.body.read

    # Calculate the HMAC-SHA256 signature
    calculated_signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), LOG_SECRET, payload_body)

    unless ActiveSupport::SecurityUtils.secure_compare(calculated_signature, signature)
      Rails.logger.warn "Signature mismatch for request from #{request.remote_ip}. Calculated: #{calculated_signature}, Received: #{signature}"
      render json: { error: 'Signature verification failed' }, status: :unauthorized
    end
  end
end
