# `xpos-infra-aro-terraform` — Infraestructura como Código (ARO 3 Zonas + PostgreSQL Flexible HA + Blob WORM)

Repositorio de Infraestructura como Código (Terraform + Operadores de OpenShift) para aprovisionar la **Opción 3 Híbrida Recomendada** en Azure Red Hat OpenShift (ARO).

---

## 1. Especificación Funcional

1. **Aislamiento de Red y Segmentación PCI-DSS (Principio P2):** Crea subredes dedicadas para los Worker Nodes del CDE (`snet-aro-workers-pci-cde`) y delegación privada VNet (`snet-postgres-flexible-ha`) con acceso público deshabilitado (`public_network_access_enabled = false`).
2. **Alta Disponibilidad Multi-Zona (Principio P4):**
   - **Streams for Apache Kafka (KRaft):** `replicas: 3`, `default.replication.factor: 3`, `min.insync.replicas: 2`, `rack.topologyKey: topology.kubernetes.io/zone`.
   - **Azure Database for PostgreSQL Flexible Server:** `ZoneRedundant` (Primario en Zona 1, Standby síncrono en Zona 2), PgBouncer integrado y extensiones `PG_PARTMAN` + `PG_CRON` habilitadas.
3. **Archivo Frío Inmutable (WORM):** Cuenta de almacenamiento `ZRS` con TLS 1.2 mínimo para exportar las particiones cerradas de `bitacora_auditoria` en formato Parquet inmutable por 13 meses.

---

## 2. Especificación Técnica y Diagrama de Arquitectura Hexagonal de Infraestructura

```mermaid
flowchart TB
    subgraph Inbound_IaC["Fuentes Declarativas (Inbound IaC)"]
        TF["Terraform Modules (main.tf)<br/>Red, PostgreSQL Flexible, Storage WORM"]
        OP["OpenShift Operators (operators/)<br/>Strimzi Kafka KRaft + Keycloak"]
    end

    subgraph Core_Gov["Núcleo de Gobierno y Políticas Cloud"]
        POL["Políticas PCI-DSS 4.0<br/>TLS 1.2+, ZoneRedundant, Non-Public"]
        EXT["Extensiones Homologadas<br/>PG_PARTMAN, PG_CRON, PgBouncer"]
    end

    subgraph Outbound_Cloud["Proveedores Cloud / Clúster (Outbound)"]
        AZ_NET["Azure VNet + Private Subnets"]
        AZ_PG["Azure PostgreSQL Flexible Server 16"]
        AZ_BLOB["Azure Blob Storage ZRS (WORM)"]
        ARO_KAF["ARO Kafka KRaft (3 Zonas)"]
    end

    TF --> POL --> AZ_NET
    POL --> AZ_PG
    POL --> AZ_BLOB
    EXT --> AZ_PG
    OP --> ARO_KAF
```

---

## 3. Modelo de Datos de Estado e Inventario de Recursos (ER Diagram)

```mermaid
erDiagram
    RESOURCE_GROUP ||--|| VIRTUAL_NETWORK : "aloja"
    VIRTUAL_NETWORK ||--|{ SUBNET : "segmenta en"
    SUBNET ||--|| POSTGRES_FLEXIBLE_SERVER : "delega a"
    SUBNET ||--|{ ARO_NODE_POOL_PCI : "conecta"
    POSTGRES_FLEXIBLE_SERVER ||--|{ SERVER_CONFIGURATION : "parametriza"
    RESOURCE_GROUP ||--|| STORAGE_ACCOUNT_WORM : "contiene"

    RESOURCE_GROUP {
        string name PK
        string location "southcentralus"
        string tag_AlcancePCI "CDE-InScope"
    }

    POSTGRES_FLEXIBLE_SERVER {
        string name PK
        string version "16"
        string ha_mode "ZoneRedundant"
        boolean public_network_access "false"
        int backup_retention_days "35"
    }

    SERVER_CONFIGURATION {
        string name PK "azure.extensions | shared_preload_libraries | pgbouncer.enabled"
        string value "PG_PARTMAN,PG_CRON | pg_cron,pg_partman_bgw | true"
    }

    STORAGE_ACCOUNT_WORM {
        string name PK
        string replication "ZRS"
        string min_tls "TLS1_2"
    }
```

---

## 4. Diagrama de Clases / Módulos de Infraestructura

```mermaid
classDiagram
    class TerraformRootModule {
        +String location
        +String environment
        +String pg_admin_username
        +provisionNetwork()
        +provisionPostgresFlexibleHa()
        +provisionStorageWorm()
    }

    class PostgresFlexibleHaConfig {
        +String version = "16"
        +String highAvailabilityMode = "ZoneRedundant"
        +String azureExtensions = "PG_PARTMAN,PG_CRON,PGCRYPTO"
        +String sharedPreloadLibraries = "pg_cron,pg_partman_bgw"
        +boolean pgbouncerEnabled = true
    }

    class KafkaKraftClusterSpec {
        +int replicas = 3
        +int replicationFactor = 3
        +int minInsyncReplicas = 2
        +String compressionType = "lz4"
        +String topologyKey = "topology.kubernetes.io/zone"
    }

    TerraformRootModule *-- PostgresFlexibleHaConfig
    TerraformRootModule ..> KafkaKraftClusterSpec
```

---

## 5. Diagrama de Secuencia de Aprovisionamiento Automatizado

```mermaid
sequenceDiagram
    autonumber
    actor SRE as Cloud Architect / SRE
    participant GH as GitHub Actions (terraform-ci.yml)
    participant AZ as Azure Resource Manager (ARM)
    participant ARO as OpenShift Operator Hub (ARO)

    SRE->>GH: Pull Request con cambios en main.tf / operators/
    GH->>GH: terraform fmt -check & terraform validate
    SRE->>GH: Aprobación y Merge a main
    GH->>AZ: Provisionar VNet + Subredes delegadas
    GH->>AZ: Crear PostgreSQL 16 Flexible Server (ZoneRedundant + PgBouncer + pg_partman)
    GH->>AZ: Crear Storage Account ZRS con contenedor Parquet WORM
    GH->>ARO: Aplicar CRD KafkaNodePool y Kafka (KRaft, RF=3, 3 Zonas)
```

---

## 6. Códigos de Estado y Compuertas de Cumplimiento

| Código / Regla | Componente | Criterio Obligatorio |
| :--- | :--- | :--- |
| `IAC-PCI-NET-01` | PostgreSQL Flexible Server | `public_network_access_enabled = false` (solo VNet privada) |
| `IAC-PCI-PG-02` | Extensiones de Particionamiento | `azure.extensions = PG_PARTMAN,PG_CRON,PGCRYPTO` |
| `IAC-HA-KAF-03` | Streams for Apache Kafka | `default.replication.factor = 3` y `min.insync.replicas = 2` |
| `IAC-PCI-WORM-04` | Azure Blob Storage | `min_tls_version = TLS1_2` y replicación `ZRS` |

---

## 7. Runbook Operativo de Infraestructura

1. **Validación Local:**
   ```bash
   terraform init -backend=false
   terraform validate
   ```
2. **Prueba de Failover de Zona en PostgreSQL Flexible Server (Chaos Testing del Piloto):**
   ```bash
   az postgres flexible-server restart --resource-group rg-xpos-integracion-aro-prod-pci --name psql-xpos-reversos-prod-pci --failover Forced
   ```
   Verificar que el RTO sea menor a 60 segundos y que el servicio Quarkus reconecte transparentemente a través de PgBouncer sin perder mensajes de Kafka.
