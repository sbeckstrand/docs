# Use an official Python image
FROM python:3.13-slim

# Install pipenv
RUN pip install pipenv

# Set work directory
WORKDIR /app

# Copy project files
COPY . .

# Install dependencies using pipenv
RUN pipenv install --dev --system --deploy

# Expose the default MkDocs port
EXPOSE 8000

# Command to serve the documentation
CMD ["pipenv", "run", "mkdocs", "serve", "-a", "0.0.0.0:8000"]