resource "aws_vpc_peering_connection_accepter" "from_dc3" {
  count = var.peer_connection_id != "" ? 1 : 0

  vpc_peering_connection_id = var.peer_connection_id
  auto_accept               = true

  tags = { Name = "${var.project_name}-peer-dc4-from-dc3" }
}

resource "aws_route" "to_dc3" {
  count = var.peer_connection_id != "" ? 1 : 0

  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = var.peer_connection_id
}
