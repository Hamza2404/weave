package main

import (
	"k8s.io/client-go/kubernetes"

	"github.com/weaveworks/weave/common"
)

const (
	configMapName      = "weave-net"
	configMapNamespace = "kube-system"
)

// update the list of all peers that have gone through this code path
func addMyselfToPeerList(cml *configMapAnnotations, c *kubernetes.Clientset, peerName, name string) (*peerList, error) {
	var list *peerList
	err := cml.LoopUpdate(func() error {
		var err error
		list, err = cml.GetPeerList()
		if err != nil {
			return err
		}
		if !list.contains(peerName) {
			list.add(peerName, name)
			err = cml.UpdatePeerList(*list)
			if err != nil {
				return err
			}
		}
		return nil
	})
	return list, err
}

func checkIamInPeerList(cml *configMapAnnotations, c *kubernetes.Clientset, peerName string) (bool, error) {
	if err := cml.Init(); err != nil {
		return false, err
	}
	list, err := cml.GetPeerList()
	if err != nil {
		return false, err
	}
	common.Log.Debugf("[kube-peers] Checking peer %q against list %v", peerName, list)
	return list.contains(peerName), nil
}
