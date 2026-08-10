package poseidon

import (
	"fmt"
	"math/big"
	"reflect"

	"github.com/consensys/gnark/frontend"
	iden3 "github.com/iden3/go-iden3-crypto/poseidon"
)

// VK-hash binding for single-VK IVC.
//
// The IVC fold takes the previous verifying key as a witness, so a malicious prover could fold with a
// substituted key. To close that, we hash the verifying key in-circuit (Poseidon over its
// emulated coordinates) and assert it equals a pinned public commitment. The same hash is computed
// off-circuit (hashVKNative) to set that public input; because both walk the identical stdgroth16
// VerifyingKey struct in the identical order, the two hashes match by construction.
//
// gnark 0.11 ships no in-circuit VK-hash helper, so this is hand-rolled. We collect every emulated
// field Element's limbs (the leaves of E ∈ GT, the G2 GammaNeg/DeltaNeg, the G1 K[] array, and the
// commitment keys) by reflection, skipping the derived pairing-line cache (a pointer) and all
// unexported fields, then absorb them with a rate-15 Poseidon sponge.

const vkSpongeRate = 15

// collectVKLimbs walks a stdgroth16 VerifyingKey (as circuit witness or as a concrete value) and
// returns every emulated-Element limb in a deterministic order. An Element is detected by its
// exported "Limbs" slice; pointers (the Lines cache) and unexported fields are skipped.
func collectVKLimbs(vk interface{}) []frontend.Variable {
	var out []frontend.Variable
	var walk func(v reflect.Value)
	walk = func(v reflect.Value) {
		switch v.Kind() {
		case reflect.Ptr, reflect.Interface:
			return // Lines cache (derived); Element limbs are collected directly below
		case reflect.Slice, reflect.Array:
			for i := 0; i < v.Len(); i++ {
				walk(v.Index(i))
			}
		case reflect.Struct:
			t := v.Type()
			if lf, ok := t.FieldByName("Limbs"); ok && lf.Type.Kind() == reflect.Slice && lf.PkgPath == "" {
				limbs := v.FieldByName("Limbs")
				for i := 0; i < limbs.Len(); i++ {
					out = append(out, limbs.Index(i).Interface())
				}
				return
			}
			for i := 0; i < t.NumField(); i++ {
				if t.Field(i).PkgPath != "" {
					continue // unexported field
				}
				walk(v.Field(i))
			}
		}
	}
	walk(reflect.ValueOf(vk))
	return out
}

// hashVKInCircuit absorbs the verifying key's limbs with a rate-15 Poseidon sponge.
func hashVKInCircuit(api frontend.API, vk interface{}) frontend.Variable {
	limbs := collectVKLimbs(vk)
	state := frontend.Variable(0)
	for i := 0; i < len(limbs); i += vkSpongeRate {
		end := i + vkSpongeRate
		if end > len(limbs) {
			end = len(limbs)
		}
		chunk := append([]frontend.Variable{state}, limbs[i:end]...)
		state = PoseidonBn254(api, chunk)
	}
	return state
}

// hashVKNative computes the same hash off-circuit, to pin the public commitment when building witnesses.
func hashVKNative(vk interface{}) (*big.Int, error) {
	raw := collectVKLimbs(vk)
	limbs := make([]*big.Int, len(raw))
	for i, r := range raw {
		b, err := limbToBig(r)
		if err != nil {
			return nil, fmt.Errorf("limb %d: %w", i, err)
		}
		limbs[i] = b
	}
	state := big.NewInt(0)
	for i := 0; i < len(limbs); i += vkSpongeRate {
		end := i + vkSpongeRate
		if end > len(limbs) {
			end = len(limbs)
		}
		chunk := append([]*big.Int{state}, limbs[i:end]...)
		h, err := iden3.Hash(chunk)
		if err != nil {
			return nil, err
		}
		state = h
	}
	return state, nil
}

func limbToBig(v frontend.Variable) (*big.Int, error) {
	switch x := v.(type) {
	case *big.Int:
		return new(big.Int).Set(x), nil
	case big.Int:
		return new(big.Int).Set(&x), nil
	case int:
		return big.NewInt(int64(x)), nil
	case int64:
		return big.NewInt(x), nil
	case uint64:
		return new(big.Int).SetUint64(x), nil
	case string:
		b, ok := new(big.Int).SetString(x, 10)
		if !ok {
			return nil, fmt.Errorf("cannot parse limb string %q", x)
		}
		return b, nil
	default:
		return nil, fmt.Errorf("unexpected limb type %T", v)
	}
}
