# Copyright (c) 2019, 2020 Oracle Corporation and/or affiliates.  All rights reserved.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

resource "oci_core_vcn" "vcn" {
  cidr_block     = var.vcn_cidr
  compartment_id = var.compartment_id
  display_name   = var.label_prefix == "none" ? var.vcn_name : "${var.label_prefix}-${var.vcn_name}"
  dns_label      = var.vcn_dns_label

  freeform_tags = var.tags
}

// See Issue #22 for the reasoning
resource "oci_core_default_security_list" "lockdown" {
  count = var.lockdown_default_seclist ? 1 : 0
  // If variable is true, removes all rules from default security list
  manage_default_resource_id = oci_core_vcn.vcn.default_security_list_id
}

resource "oci_core_default_security_list" "restore_default" {
  count = var.lockdown_default_seclist == false ? 1 : 0

  // If variable is false, restore all default rules to default security list
  manage_default_resource_id = oci_core_vcn.vcn.default_security_list_id

  egress_security_rules {
    // allow all egress traffic
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    // allow all SSH
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    // allow ICMP for all type 3 code 4
    protocol = "1"
    source   = "0.0.0.0/0"

    icmp_options {
      type = "3"
      code = "4"
    }
  }

  ingress_security_rules {
    //allow all ICMP from VCN
    protocol = "1"
    source   = var.vcn_cidr

    icmp_options {
      type = "3"
    }
  }
}

########################
# Internet Gateway (IGW)
########################
resource "oci_core_internet_gateway" "ig" {
  compartment_id = var.compartment_id
  display_name   = var.label_prefix == "none" ? "internet-gateway" : "${var.label_prefix}-internet-gateway"

  freeform_tags = var.tags

  vcn_id = oci_core_vcn.vcn.id

  count = var.internet_gateway_enabled ? 1 : 0
}

resource "oci_core_route_table" "ig" {
  compartment_id = var.compartment_id
  display_name   = var.label_prefix == "none" ? "internet-route" : "${var.label_prefix}-internet-route"

  freeform_tags = var.tags

  route_rules {
    # * With this route table, Internet Gateway is always declared as the default gateway
    destination       = local.anywhere
    network_entity_id = oci_core_internet_gateway.ig[0].id
    description       = "Terraformed - Auto-generated at Internet Gateway creation: Internet Gateway as default gateway"
  }

  dynamic "route_rules" {
    # * filter var.internet_gateway_route_rules for routes with "drg" as destination
    # * and steer traffic to the module created DRG
    for_each = var.internet_gateway_route_rules != null ? { for k, v in var.internet_gateway_route_rules : k => v
    if v.network_entity_id == "drg" } : {}

    content {
      destination       = route_rules.value.destination
      destination_type  = route_rules.value.destination_type
      network_entity_id = oci_core_drg.drg[0].id
      description       = route_rules.value.description
    }
  }

  dynamic "route_rules" {
    # * filter var.internet_gateway_route_rules for routes with "internet_gateway" as destination
    # * and steer traffic to the module created Internet Gateway
    for_each = var.internet_gateway_route_rules != null ? { for k, v in var.internet_gateway_route_rules : k => v
    if v.network_entity_id == "internet_gateway" } : {}

    content {
      destination       = route_rules.value.destination
      destination_type  = route_rules.value.destination_type
      network_entity_id = oci_core_internet_gateway.ig[0].id
      description       = route_rules.value.description
    }
  }

  dynamic "route_rules" {
    # * filter var.internet_gateway_route_rules for generic routes
    # * can take any Named Value : String, Input Variable, Local Value, Data Source, Resource, Module Output ...
    # * useful for gateways that are not managed by the module
    for_each = var.internet_gateway_route_rules != null ? { for k, v in var.internet_gateway_route_rules : k => v
    if contains(["drg", "internet_gateway"], v.network_entity_id) == false } : {}

    content {
      destination       = route_rules.value.destination
      destination_type  = route_rules.value.destination_type
      network_entity_id = route_rules.value.network_entity_id
      description       = route_rules.value.description
    }
  }

  vcn_id = oci_core_vcn.vcn.id

  count = var.internet_gateway_enabled ? 1 : 0
}

#######################
# Service Gateway (SGW)
#######################
data "oci_core_services" "all_oci_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
  count = var.service_gateway_enabled ? 1 : 0
}

resource "oci_core_service_gateway" "service_gateway" {
  compartment_id = var.compartment_id
  display_name   = var.label_prefix == "none" ? "service-gateway" : "${var.label_prefix}-service-gateway"

  freeform_tags = var.tags
  services {
    service_id = lookup(data.oci_core_services.all_oci_services[0].services[0], "id")
  }

  vcn_id = oci_core_vcn.vcn.id

  count = var.service_gateway_enabled ? 1 : 0
}

###################
# NAT Gateway (NGW)
###################
resource "oci_core_nat_gateway" "nat_gateway" {
  compartment_id = var.compartment_id
  display_name   = var.label_prefix == "none" ? "nat-gateway" : "${var.label_prefix}-nat-gateway"

  freeform_tags = var.tags

  public_ip_id = var.nat_gateway_public_ip_id != "none" ? var.nat_gateway_public_ip_id : null

  vcn_id = oci_core_vcn.vcn.id

  count = var.nat_gateway_enabled ? 1 : 0
}

resource "oci_core_route_table" "nat" {
  compartment_id = var.compartment_id
  display_name   = var.label_prefix == "none" ? "nat-route" : "${var.label_prefix}-nat-route"

  freeform_tags = var.tags

  route_rules {
    # * With this route table, NAT Gateway is always declared as the default gateway
    destination       = local.anywhere
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat_gateway[0].id
    description       = "Terraformed - Auto-generated at NAT Gateway creation: NAT Gateway as default gateway"
  }

  dynamic "route_rules" {
    # * If Service Gateway is created with the module, automatically creates a rule to handle traffic for "all services" through Service Gateway
    for_each = var.service_gateway_enabled ? [1] : []

    content {
      destination       = lookup(data.oci_core_services.all_oci_services[0].services[0], "cidr_block")
      destination_type  = "SERVICE_CIDR_BLOCK"
      network_entity_id = oci_core_service_gateway.service_gateway[0].id
      description       = "Terraformed - Auto-generated at Service Gateway creation: All Services in region to Service Gateway"
    }
  }

  dynamic "route_rules" {
    # * filter var.nat_gateway_route_rules for routes with "drg" as destination
    # * and steer traffic to the module created DRG
    for_each = var.nat_gateway_route_rules != null ? { for k, v in var.nat_gateway_route_rules : k => v
    if v.network_entity_id == "drg" } : {}

    content {
      destination       = route_rules.value.destination
      destination_type  = route_rules.value.destination_type
      network_entity_id = oci_core_drg.drg[0].id
      description       = route_rules.value.description
    }
  }

  dynamic "route_rules" {
    # * filter var.nat_gateway_route_rules for routes with "nat_gateway" as destination
    # * and steer traffic to the module created NAT Gateway
    for_each = var.nat_gateway_route_rules != null ? { for k, v in var.nat_gateway_route_rules : k => v
    if v.network_entity_id == "nat_gateway" } : {}

    content {
      destination       = route_rules.value.destination
      destination_type  = route_rules.value.destination_type
      network_entity_id = oci_core_nat_gateway.nat_gateway[0].id
      description       = route_rules.value.description
    }
  }

  dynamic "route_rules" {
    # * filter var.internet_gateway_route_rules for generic routes
    # * can take any Named Value : String, Input Variable, Local Value, Data Source, Resource, Module Output ...
    # * useful for gateways that are not managed by the module
    for_each = var.nat_gateway_route_rules != null ? { for k, v in var.nat_gateway_route_rules : k => v
    if contains(["drg", "nat_gateway"], v.network_entity_id) == false } : {}

    content {
      destination       = route_rules.value.destination
      destination_type  = route_rules.value.destination_type
      network_entity_id = route_rules.value.network_entity_id
      description       = route_rules.value.description
    }
  }

  vcn_id = oci_core_vcn.vcn.id

  count = var.nat_gateway_enabled ? 1 : 0
}

###############################
# Dynamic Routing Gateway (DRG)
###############################
resource "oci_core_drg" "drg" {
  compartment_id = var.compartment_id
  display_name   = var.label_prefix == "none" ? var.drg_display_name : "${var.label_prefix}-drg"

  freeform_tags = var.tags

  count = var.create_drg ? 1 : 0
}

resource "oci_core_drg_attachment" "drg" {
  drg_id = oci_core_drg.drg[count.index].id
  vcn_id = oci_core_vcn.vcn.id

  count = var.create_drg ? 1 : 0
}
