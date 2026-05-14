# Flex Router

Yearn V3 vault integration for Flex isolated lending.

## Active Contracts

- `FlexRouter` in `src/`

Flex lender and allocator strategy contracts are imported from
`lib/flex-contracts` on the `allocator` branch.

## Active Tests

The live fork suite is:

```sh
forge test --match-contract FlexAllocatorTest -vv
```
