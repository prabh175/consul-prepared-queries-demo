resource "aws_vpc_peering_connection" "to_dc4" {
  count = var.peer_vpc_id != "" ? 1 : 0

  vpc_id      = aws_vpc.this.id
  peer_vpc_id = var.peer_vpc_id
  peer_region = var.peer_region
  auto_accept = false

  tags = { Name = "${var.project_name}-peer-dc3-to-dc4" }
}

resource "aws_route" "to_dc4" {
  count = var.peer_vpc_id != "" ? 1 : 0

  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_dc4[0].id
}
