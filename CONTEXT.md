# Bernstein

The deployment process of the Poll application, from its supplied sources to a Kubernetes cluster.

## Language

**Application**:
Poll, Worker or Result: the three programs built from the supplied sources.
_Avoid_: service, component

**Backing store**:
Redis or PostgreSQL, run from their public images.
_Avoid_: service, component, dependency

**Page**:
What a visitor reaches: the Poll page to vote, the Result page to read the tally.
_Avoid_: frontend, site

**Vote**:
One voter's choice among the four options. A voter has a single current vote, replaced when they vote again.
_Avoid_: ballot

**Voter**:
A browser, identified by its `voter_id` cookie.
_Avoid_: user

**Queue**:
The Redis list `votes`, where a vote waits between Poll and the Worker. Transit only: nothing is kept there.
_Avoid_: buffer, store

**Tally**:
The number of votes per option, read from PostgreSQL by Result.
_Avoid_: score, count

**Update**:
Redeploying after the sources of one application changed, with no failed request.
_Avoid_: upgrade, which is for the cluster

**Upgrade**:
AKS replacing the Kubernetes version or the node image of the cluster.
_Avoid_: update
