terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0" # Add Kubernetes provider for GKE interaction
    }
    kubectl = {
      source  = "hashicorp/kubectl"
      version = "~> 2.0" # Add kubectl provider for applying manifests
    }
  }
}

provider "google" {
  project = "<YOUR_GCP_PROJECT_ID>"
  region  = "us-central1"
  zone    = "us-central1-a"
}

# Add provider configuration for Kubernetes.  This uses the GKE cluster
# created below to get the necessary connection information.
provider "kubernetes" {
  host                   = google_container_cluster.prod_cluster.endpoint
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.prod_cluster.master_auth[0].cluster_ca_certificate)
}

# Add provider configuration for kubectl.  This also uses the GKE cluster.
provider "kubectl" {
  host                   = google_container_cluster.prod_cluster.endpoint
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.prod_cluster.master_auth[0].cluster_ca_certificate)
}

# Get the client config for authentication with the GKE cluster.
data "google_client_config" "default" {}


#-------------------------------------------------------------------------------
# Networking
#-------------------------------------------------------------------------------

resource "google_compute_network" "vpc" {
  name                    = "my-app-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "dev_subnet" {
  name          = "dev-subnet"
  ip_cidr_range = "10.1.0.0/24"
  network       = google_compute_network.vpc.id
  region        = provider.google.region
}

resource "google_compute_subnetwork" "prod_subnet" {
  name          = "prod-subnet"
  ip_cidr_range = "10.2.0.0/24"
  network       = google_compute_network.vpc.id
  network       = google_compute_network.vpc.id
  region        = provider.google.region
}

#-------------------------------------------------------------------------------
# Cloud SQL
#-------------------------------------------------------------------------------

resource "google_sql_database_instance" "main" {
  name             = "my-app-db"
  region           = provider.google.region
  database_version = "POSTGRES_15" # Or "MYSQL_8_0"
  settings {
    tier = "db-f1-micro" #  Choose appropriate tier
    ip_configuration {
      ipv4_enabled = false
      private_network = google_compute_network.vpc.id
    }
  }
}

resource "google_sql_database" "dev_db" {
  name     = "development"
  instance = google_sql_database_instance.main.name
}

resource "google_sql_database" "prod_db" {
  name     = "production"
  instance = google_sql_database_instance.main.name
}

#-------------------------------------------------------------------------------
# Development Environment (Cloud Run)
#-------------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "dev_python_app" {
  name     = "dev-python-app"
  location = provider.google.region
  template {
    containers {
      image = "python:3.9-slim-buster" #  Replace with your container image
      envs = [
        {
          name  = "DATABASE_HOST"
          value = google_sql_database_instance.main.private_ip_address
        },
        {
          name  = "DATABASE_NAME"
          value = google_sql_database.dev_db.name
        },
        {
          name  = "DATABASE_USER"
          value = "dev_db_user" #  Use Secret Manager in production
        },
        {
          name  = "DATABASE_PASSWORD"
          value = "dev_db_password" #  Use Secret Manager
        },
      ]
    }
  }
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
  depends_on = [google_sql_database_instance.main]
}

resource "google_cloud_run_v2_service" "dev_java_app" {
  name     = "dev-java-app"
  location = provider.google.region
  template {
    containers {
      image = "openjdk:17-jdk-slim" # Replace with your container image
      envs = [
        {
          name  = "DATABASE_HOST"
          value = google_sql_database_instance.main.private_ip_address
        },
        {
          name  = "DATABASE_NAME"
          value = google_sql_database.dev_db.name
        },
        {
          name  = "DATABASE_USER"
          value = "dev_db_user" #  Use Secret Manager in production
        },
        {
          name  = "DATABASE_PASSWORD"
          value = "dev_db_password" # Use Secret Manager
        },
      ]
    }
  }
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
  depends_on = [google_sql_database_instance.main]
}

#-------------------------------------------------------------------------------
# Production Environment (GKE Autopilot)
#-------------------------------------------------------------------------------

resource "google_container_cluster" "prod_cluster" {
  name_prefix = "prod-cluster"
  location    = provider.google.region
  release_channel {
    channel = "STABLE"
  }
  autopilot {
    enabled = true
  }
  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.prod_subnet.id
}

#  Example Kubernetes Deployments and Services using kubectl_manifest
#  For more complex deployments, consider using the kubernetes provider.
resource "kubectl_manifest" "prod_python_deployment" {
  yaml_body = <<-YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prod-python-app
  namespace: default #  Consider using namespaces
spec:
  replicas: 3
  selector:
    matchLabels:
      app: prod-python-app
  template:
    metadata:
      labels:
        app: prod-python-app
    spec:
      containers:
        - name: python-app
          image: "your-registry/prod-python-image:latest" # Replace with your production image
          env:
            - name: DATABASE_HOST
              value: ${google_sql_database_instance.main.private_ip_address}
            - name: DATABASE_NAME
              value: ${google_sql_database.prod_db.name}
            - name: DATABASE_USER
              value: "prod_db_user" #  Use Secret Manager
            - name: DATABASE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: prod-db-credentials #  Reference a Kubernetes Secret
                  key: password
  YAML
  depends_on = [google_container_cluster.prod_cluster, google_sql_database_instance.main]
}

resource "kubectl_manifest" "prod_python_service" {
  yaml_body = <<-YAML
apiVersion: v1
kind: Service
metadata:
  name: prod-python-service
  namespace: default #  Consider using namespaces
spec:
  selector:
    app: prod-python-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080 #  Your application port
  type: LoadBalancer #  Or ClusterIP for internal access
  YAML
  depends_on = [kubectl_manifest.prod_python_deployment]
}

resource "kubectl_manifest" "prod_java_deployment" {
  yaml_body = <<-YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prod-java-app
  namespace: default #  Consider using namespaces
spec:
  replicas: 3
  selector:
    matchLabels:
      app: prod-java-app
  template:
    metadata:
      labels:
        app: prod-java-app
    spec:
      containers:
        - name: java-app
          image: "your-registry/prod-java-image:latest" #  Replace with your production image
          env:
            - name: DATABASE_HOST
              value: ${google_sql_database_instance.main.private_ip_address}
            - name: DATABASE_NAME
              value: ${google_sql_database.prod_db.name}
            - name: DATABASE_USER
              value: "prod_db_user" # Use Secret Manager
            - name: DATABASE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: prod-db-credentials # Reference a Kubernetes Secret
                  key: password
  YAML
  depends_on = [google_container_cluster.prod_cluster, google_sql_database_instance.main]
}

resource "kubectl_manifest" "prod_java_service" {
  yaml_body = <<-YAML
apiVersion: v1
kind: Service
metadata:
  name: prod-java-service
  namespace: default #  Consider using namespaces
spec:
  selector:
    app: prod-java-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080 # Your application port
  type: LoadBalancer #  Or ClusterIP for internal access
  YAML
  depends_on = [kubectl_manifest.prod_java_deployment]
}

#  Example Kubernetes Secret for Production Database Credentials
resource "kubectl_manifest" "prod_db_secret" {
  yaml_body = <<-YAML
apiVersion: v1
kind: Secret
metadata:
  name: prod-db-credentials
  namespace: default # Consider using namespaces
type: Opaque
data:
  username: ${base64encode("prod_db_user")} #  Replace with your actual username
  password: ${base64encode("prod_db_password")} #  Use Secret Manager in a real setup
  YAML
  depends_on = [google_sql_database.prod_db]
}


#-------------------------------------------------------------------------------
# Security Best Practices
#-------------------------------------------------------------------------------

# 1. IAM Roles and Permissions:
#    -  Create service accounts for Cloud Run and GKE.
resource "google_service_account" "cloudrun_sa" {
  account_id   = "cloudrun-sa"
  display_name = "Cloud Run Service Account"
}

resource "google_service_account" "gke_sa" {
  account_id   = "gke-sa"
  display_name = "GKE Service Account"
}

#    -  Grant the Cloud Run service account the necessary permissions.
resource "google_project_iam_member" "cloudrun_access_sql" {
  project = provider.google.project
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.cloudrun_sa.email}"
}

#    -  Grant the GKE service account the necessary permissions.  This is a broad example;
#       in a production environment, you'd want to restrict this further.
resource "google_project_iam_member" "gke_access_resources" {
  project = provider.google.project
  role    = "roles/container.developer" #  Example:  More specific roles are better.
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

#    -  Associate the service accounts with Cloud Run and GKE resources.
resource "google_cloud_run_v2_service" "dev_python_app_sa" {
  name     = "dev-python-app"
  location = provider.google.region
  template {
    containers {
      image = "python:3.9-slim-buster"
      envs = [
        {
          name  = "DATABASE_HOST"
          value = google_sql_database_instance.main.private_ip_address
        },
        {
          name  = "DATABASE_NAME"
          value = google_sql_database.dev_db.name
        },
        {
          name  = "DATABASE_USER"
          value = "dev_db_user" #  Use Secret Manager
        },
        {
          name  = "DATABASE_PASSWORD"
          value = "dev_db_password" # Use Secret Manager
        },
      ]
      security_context {
        run_as_user = 0 # Example:  Run as non-root if possible
      }
    }
    execution_environment = "EXECUTION_ENVIRONMENT_SECURE" # Use secure environment
    service_account       = google_service_account.cloudrun_sa.email
  }
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
  depends_on = [google_sql_database_instance.main, google_service_account.cloudrun_sa]
}

resource "google_cloud_run_v2_service" "dev_java_app_sa" {
  name     = "dev-java-app"
  location = provider.google.region
  template {
    containers {
      image = "openjdk:17-jdk-slim"
       envs = [
        {
          name  = "DATABASE_HOST"
          value = google_sql_database_instance.main.private_ip_address
        },
        {
          name  = "DATABASE_NAME"
          value = google_sql_database.dev_db.name
        },
        {
          name  = "DATABASE_USER"
          value = "dev_db_user" #  Use Secret Manager
        },
        {
          name  = "DATABASE_PASSWORD"
          value = "dev_db_password" # Use Secret Manager
        },
      ]
      security_context {
        run_as_user = 0 # Example
      }
    }
    execution_environment = "EXECUTION_ENVIRONMENT_SECURE"
    service_account       = google_service_account.cloudrun_sa.email
  }
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
  depends_on = [google_sql_database_instance.main, google_service_account.cloudrun_sa]
}

resource "google_container_cluster" "prod_cluster_sa" {
  name_prefix = "prod-cluster"
  location    = provider.google.region
  release_channel {
    channel = "STABLE"
  }
  autopilot {
    enabled = true
  }
  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.prod_subnet.id
  #  Associate the GKE service account with the node pool.
  node_pool {
    name = "default-pool" #  The default node pool
    config {
      service_account = google_service_account.gke_sa.email
      oauth_scopes = [
        "https://www.googleapis.com/auth/cloud-platform", #  Full access (restrict as needed)
      ]
    }
  }
}



# 2. Cloud SQL Security:
#    - Private IP is configured.
#    - Database user management is handled within the database itself.
#    -  Use Cloud SQL Auth proxy for connections from outside GCP (if needed).  This
#       would typically involve a separate deployment within your GKE cluster,
#       but for simplicity, we'll focus on the private IP connection.

# 3. Secret Management:
#    - Use Google Cloud Secret Manager for production secrets.
resource "google_secret_manager_secret" "prod_db_password_secret" {
  secret_id = "prod-db-password"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "prod_db_password_version" {
  secret      = google_secret_manager_secret.prod_db_password_secret.id
  secret_data = "your_production_database_password" #  Store the actual secret securely.
}

#  Example of using Secret Manager with Cloud Run.
resource "google_cloud_run_v2_service" "prod_python_app_sm" {
  name     = "prod-python-app"
  location = provider.google.region
  template {
    containers {
      image = "your-registry/prod-python-image:latest"
      envs = [
        {
          name  = "DATABASE_HOST"
          value = google_sql_database_instance.main.private_ip_address
        },
        {
          name  = "DATABASE_NAME"
          value = google_sql_database.prod_db.name
        },
         {
          name  = "DATABASE_USER"
          value = "prod_db_user" #  Ideally, this would also come from a secret.
        },
        {
          name  = "DATABASE_PASSWORD"
          value_from {
            secret_key_ref {
              secret  = google_secret_manager_secret.prod_db_password_secret.id
              version = "latest" #  Or a specific version
            }
          }
        },
      ]
       security_context {
        run_as_user = 0 # Example
      }
    }
    service_account = google_service_account.cloudrun_sa.email #  Use the service account
  }
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
  depends_on = [google_sql_database_instance.main, google_secret_manager_secret_version.prod_db_password_version, google_service_account.cloudrun_sa]
}

resource "google_cloud_run_v2_service" "prod_java_app_sm" {
  name     = "prod-java-app"
  location = provider.google.region
  template {
    containers {
      image = "your-registry/prod-java-image:latest"
      envs = [
        {
          name  = "DATABASE_HOST"
          value = google_sql_database_instance.main.private_ip_address
        },
        {
          name  = "DATABASE_NAME"
          value = google_sql_database.prod_db.name
        },
        {
          name  = "DATABASE_USER"
          value = "prod_db_user" #  Ideally, this would also come from a secret.
        },
        {
          name  = "DATABASE_PASSWORD"
          value_from {
            secret_key_ref {
              secret  = google_secret_manager_secret.prod_db_password_secret.id
              version = "latest" #  Or a specific version
            }
          }
        },
      ]
      security_context {
        run_as_user = 0 # Example
      }
    }
    service_account = google_service_account.cloudrun_sa.email # Use the service account.
  }
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
   depends_on = [google_sql_database_instance.main, google_secret_manager_secret_version.prod_db_password_version, google_service_account.cloudrun_sa]
}



#  Example of using Secret Manager with GKE using a Kubernetes Secret.  In a
#  real-world scenario, you might use the Secret Manager CSI driver for
#  better security and manageability.  This example demonstrates creating
#  the secret, but the actual retrieval from Secret Manager and population
#  of the Kubernetes Secret would typically be done outside of Terraform
#  (e.g., using a separate script or tool) or using the CSI driver.
resource "kubectl_manifest" "prod_db_secret_sm" {
  yaml_body = <<-YAML
apiVersion: v1
kind: Secret
metadata:
  name: prod-db-credentials
  namespace: default
type: Opaque
data:
  username: ${base64encode("prod_db_user")} #  Ideally from Secret Manager
  password: ${base64encode("prod_db_password_value")} #  This should come from Secret Manager
  YAML
  depends_on = [google_sql_database.prod_db]
}


# 4. Network Security:
#    - VPC and subnets are configured.
#    -  Example:  Create a firewall rule to allow traffic to the GKE cluster.  Restrict this
#       rule as much as possible.
resource "google_compute_firewall" "gke_allow_http" {
  name    = "gke-allow-http"
  network = google_compute_network.vpc.id
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"] #  Restrict to necessary ports.
  }
  source_ranges = ["0.0.0.0/0"] #  Restrict to known IPs if possible
  target_tags   = ["gke-node"] #  Apply to GKE nodes
}

#    -  Tag the GKE nodes so the firewall rule applies.
resource "google_container_cluster" "prod_cluster_tagged" {
  name_prefix = "prod-cluster"
  location    = provider.google.region
  release_channel {
    channel = "STABLE"
  }
  autopilot {
    enabled = true
  }
  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.prod_subnet.id
  #  Tag the nodes.
  node_pool {
    name = "default-pool"
    config {
      service_account = google_service_account.gke_sa.email
      oauth_scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
      ]
      tags = ["gke-node"] #  Apply the tag here
    }
  }
  depends_on = [google_service_account.gke_sa]
}


# 5. GKE Security:
#    -  Autopilot handles many security aspects.
#    -  Example:  Implement a Network Policy to restrict pod-to-pod traffic.
resource "kubectl_manifest" "default_deny_all_policy" {
  yaml_body = <<-YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  YAML
  depends_on = [google_container_cluster.prod_cluster]
}

# 6. Cloud Run Security
#   -  Secure Environment.
#   -  Use Service Accounts.
#   -  Principle of Least Privilege.

# 7.  Logging and Monitoring
#   -   Terraform does not directly configure logging and monitoring, but you can
#       create the necessary resources (e.g., log sinks) using
#       `google_logging_project_sink` and related resources.

#  Example Log Sink
resource "google_logging_project_sink" "my_log_sink" {
  name   = "my-log-sink"
  project = provider.google.project
  filter = "LOG_FILTER" #  Define your log filter
  destination = "storage.googleapis.com/my-logging-bucket" #  Replace with your bucket
}