# Proposal: Add support for CIDR notation in no_proxy variable

Author(s): Rudi Kramer, James Forrest

Last updated: 2017-07-10

Discussion at https://golang.org/issue/16704.

## Abstract

The old convention for no_proxy is to use a full domain name, a partial domain
name, a singular ip address or a  combination.

The newer convention is to allow users to add in networks using the CIDR
notation. This proposal aims to update Go to allow for CIDR notation in
no_proxy.

## Background

There is no official spec for no_proxy but the older convention was to use only
domain names, partial domain names or singular IP addresses.
Many applications and programming languages have started to allow users to
specify networks using the CIDR notation.

## Proposal

This proposal is to update Go Net/HTTP to allow users to either add in IPv4/CIDR
or IPv6/CIDR ranges in to the no_proxy env and have Go correctly route traffic
based on these networks.

## Rationale

Networks are becoming more and more complex and with the advent of applications
like Kubernetes, it's becoming more important than ever to allow for network
ranges to be specified in Go, from the user space and the most common convention
is to use the no_proxy env.

To use the current no_proxy implementation I would need to add in 65534
individual IP addresses into no_proxy in order to resolve issues like
https://github.com/projectcalico/calico/issues/872.

## Compatibility

This change will not affect any backwards compatibility or introduce any
breaking changes to existing applications except to properly implement CIDR
notation where it is currently not working.

## Implementation

The python method for determining if the request URL is going to be bypass the proxy due it being in the no_proxy list accepts two arguments, request URL and no_proxy.

The first thing that happens is that no_proxy is either used from the passed in argument or set from the environment variables. Next the request URL is separated into the domain and port number only. Also known as the netloc.

If the no_proxy variable is set then the method checks to see if the request URL is a valid ip address.

If the request  url is a valid ip address then the method iterates over all the entries in the no_proxy array.
If the no_proxy entry is a network in CIDR notation and matches the request ip then the proxy is bypassed.
If the no_proxy entry is a singular ip address and matches the request URL then the proxy is bypassed.

If the request URL is not a valid IP address then it's assumed that it's a hostname.  
The method then iterates over all entries in the no_proxy array.
If the request_url hostname ends with the netloc, the proxy is bypassed.

## Open issues (if applicable)
