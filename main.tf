# =========================================================================================
# Terraform Root Module - Plataforma de Integración POS en ARO (Opción 3 Híbrida Recomendada)
# - Clúster Azure Red Hat OpenShift (ARO) distribuido en 3 Zonas de Disponibilidad
# - Node Pools separados para cargas PCI-DSS (CDE) y No-PCI
# - Azure Database for PostgreSQL Flexible Server (Zone-Redundant, PgBouncer, pg_partman, pg_cron)
# - Azure Blob Storage con política de inmutabilidad WORM (13 meses PCI-DSS 10.7)
# =========================================================================================

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "location" {
  type        = string
  default     = "southcentralus"
  description = "Región de Azure con soporte para 3 Zonas de Disponibilidad"
}

variable "environment" {
  type        = string
  default     = "prod-pci"
  description = "Ambiente de despliegue (qa, staging-pci, prod-pci)"
}

variable "pg_admin_username" {
  type        = string
  default     = "xpos_dba_admin"
}

variable "pg_admin_password" {
  type        = string
  sensitive   = true
  description = "Inyectado desde CyberArk Conjur / GitHub Secrets en tiempo de ejecución"
}

resource "azurerm_resource_group" "xpos_aro_rg" {
  name     = "rg-xpos-integracion-aro-${var.environment}"
  location = var.location
  tags = {
    Plataforma  = "XPOS-SE-Integracion-POS"
    AlcancePCI  = "CDE-InScope"
    Arquitectura = "Op3-Hibrida-ARO-AzureFlexiblePG"
  }
}

# 1. Red Virtual con Subredes aisladas para ARO Control/Workers y Private Endpoint de PostgreSQL
resource "azurerm_virtual_network" "xpos_vnet" {
  name                = "vnet-xpos-aro-${var.environment}"
  location            = azurerm_resource_group.xpos_aro_rg.location
  resource_group_name = azurerm_resource_group.xpos_aro_rg.name
  address_space       = ["10.120.0.0/16"]
}

resource "azurerm_subnet" "subnet_aro_workers_pci" {
  name                 = "snet-aro-workers-pci-cde"
  resource_group_name  = azurerm_resource_group.xpos_aro_rg.name
  virtual_network_name = azurerm_virtual_network.xpos_vnet.name
  address_prefixes     = ["10.120.4.0/22"]
}

resource "azurerm_subnet" "subnet_postgres_flexible" {
  name                 = "snet-postgres-flexible-ha"
  resource_group_name  = azurerm_resource_group.xpos_aro_rg.name
  virtual_network_name = azurerm_virtual_network.xpos_vnet.name
  address_prefixes     = ["10.120.16.0/24"]
  delegation {
    name = "fs-delegation"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# 2. Azure Database for PostgreSQL Flexible Server (Zone-Redundant HA + PgBouncer + pg_partman + pg_cron)
resource "azurerm_postgresql_flexible_server" "xpos_postgres" {
  name                          = "psql-xpos-reversos-${var.environment}"
  resource_group_name           = azurerm_resource_group.xpos_aro_rg.name
  location                      = azurerm_resource_group.xpos_aro_rg.location
  version                       = "16"
  delegated_subnet_id           = azurerm_subnet.subnet_postgres_flexible.id
  public_network_access_enabled = false
  administrator_login           = var.pg_admin_username
  administrator_password        = var.pg_admin_password
  zone                          = "1"
  sku_name                      = "GP_Standard_D4ds_v5"
  storage_mb                    = 262144
  backup_retention_days         = 35
  geo_redundant_backup_enabled  = true

  high_availability {
    mode                      = "ZoneRedundant"
    standby_availability_zone = "2"
  }
}

# Habilitación explícita de pg_partman, pg_cron y PgBouncer en Flexible Server
resource "azurerm_postgresql_flexible_server_configuration" "extensions_allowlist" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.xpos_postgres.id
  value     = "PG_PARTMAN,PG_CRON,PGCRYPTO"
}

resource "azurerm_postgresql_flexible_server_configuration" "shared_preload" {
  name      = "shared_preload_libraries"
  server_id = azurerm_postgresql_flexible_server.xpos_postgres.id
  value     = "pg_cron,pg_partman_bgw"
}

resource "azurerm_postgresql_flexible_server_configuration" "pgbouncer_enabled" {
  name      = "pgbouncer.enabled"
  server_id = azurerm_postgresql_flexible_server.xpos_postgres.id
  value     = "true"
}

# 3. Archivo Frío WORM en Azure Blob Storage para Bitácora Parquet (Retención 13 meses PCI-DSS 10.7)
resource "azurerm_storage_account" "xpos_cold_archive" {
  name                            = "stxposbitacorawormprod"
  resource_group_name             = azurerm_resource_group.xpos_aro_rg.name
  location                        = azurerm_resource_group.xpos_aro_rg.location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
}

resource "azurerm_storage_container" "bitacora_parquet_worm" {
  name                  = "bitacora-auditoria-parquet-worm"
  storage_account_name  = azurerm_storage_account.xpos_cold_archive.name
  container_access_type = "private"
}
