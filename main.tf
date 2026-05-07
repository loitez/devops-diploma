terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }

  backend "s3" {
    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }
    bucket   = "loitez-diploma-tfstate"
    region   = "ru-central1"
    key      = "terraform.tfstate"

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true

    force_path_style            = true
  }
}

provider "yandex" {
  cloud_id  = "b1gojvp01s0t4gf4m1qn"
  folder_id = "b1gr6f3vahpkkk2de11c"
  zone      = "ru-central1-a"
}

resource "yandex_vpc_network" "diploma-net" {
  name = "diploma-network"
}

# 1. Подсеть, где будут жить узлы
resource "yandex_vpc_subnet" "diploma-subnet" {
  name           = "diploma-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.diploma-net.id
  v4_cidr_blocks = ["10.1.0.0/24"]
}

# 2. Сервисный аккаунт для управления кластером
resource "yandex_iam_service_account" "k8s-sa" {
  name        = "k8s-sa"
  description = "SA для управления кластером"
}

# Назначение ролей для управления
resource "yandex_resourcemanager_folder_iam_member" "k8s-clusters-agent" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "k8s.clusters.agent"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "vpc-public-admin" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "vpc.publicAdmin"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
}

# 3. Сервисный аккаунт для узлов (чтобы качать образы из Registry)
resource "yandex_iam_service_account" "nodes-sa" {
  name        = "nodes-sa"
  description = "SA для нод кластера"
}

resource "yandex_resourcemanager_folder_iam_member" "images-puller" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "container-registry.images.puller"
  member    = "serviceAccount:${yandex_iam_service_account.nodes-sa.id}"
}

# 4. Сам кластер Kubernetes
resource "yandex_kubernetes_cluster" "k8s-cluster" {
  name        = "k8s-diploma"
  network_id  = yandex_vpc_network.diploma-net.id

  master {
    zonal {
      zone      = "ru-central1-a"
      subnet_id = yandex_vpc_subnet.diploma-subnet.id
    }
    public_ip = true # Чтобы мы могли подключиться через kubectl
  }

  service_account_id      = yandex_iam_service_account.k8s-sa.id
  node_service_account_id = yandex_iam_service_account.nodes-sa.id

  depends_on = [
    yandex_resourcemanager_folder_iam_member.k8s-clusters-agent,
    yandex_resourcemanager_folder_iam_member.vpc-public-admin
  ]
}

# 5. Группа узлов (Node Group) — реальные виртуалки
resource "yandex_kubernetes_node_group" "k8s-node-group" {
  cluster_id  = yandex_kubernetes_cluster.k8s-cluster.id
  name        = "worker-nodes"

  instance_template {
    platform_id = "standard-v2"

    network_interface {
      nat                = true
      subnet_ids         = [yandex_vpc_subnet.diploma-subnet.id]
    }

    resources {
      memory = 4
      cores  = 2
    }

    boot_disk {
      type = "network-hdd"
      size = 64
    }
  }

  scale_policy {
    fixed_scale {
      size = 2 # Количество нод
    }
  }
}

# 6. Реестр для Docker-образов
resource "yandex_container_registry" "diploma-registry" {
  name = "diploma-registry"
}

# Роль для создания балансировщика
resource "yandex_resourcemanager_folder_iam_member" "k8s-lb-admin" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "load-balancer.admin"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
}

# Роль для управления сетевыми ресурсами (нужна для связи балансировщика с нодами)
resource "yandex_resourcemanager_folder_iam_member" "k8s-vpc-public-admin" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "vpc.publicAdmin"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
}
