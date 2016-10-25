// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

using Microsoft.VisualStudio.Debugger.Interop;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Microsoft.MIDebugEngine
{
    public enum AsyncStopState : int
    {
        None,          // No async stop has been requested
        Pending,       // An async stop request was sent to the base dm
        Sent,          // An async stop request was sent (or it is in route) to the SDM
        StoppingEventInRoute, // we are just about to send an event to the SDM
        StopProcessingComplete // Another stopping event is already in route to the SDM
    }
    internal class AD7StoppingEventProcessor
    {
        private volatile int _asyncStopState = (int)AsyncStopState.None;

        private IDebugThread2 _lastEventThread;

        private AD7Engine _engine;
        private EngineCallback _engineCallback;

        internal IDebugThread2 LastEventThread
        {
            get
            {
                return _lastEventThread;
            }

            set
            {
                if (_lastEventThread != value)
                {
                    _lastEventThread = value;
                }
            }
        }

        public AD7StoppingEventProcessor(AD7Engine engine, EngineCallback engineCallback)
        {
            _engine = engine;
            _engineCallback = engineCallback;
        }

        public bool BeforeAsyncStop()
        {
            while (true)
            {
                AsyncStopState snapshot = (AsyncStopState)_asyncStopState;

                switch (snapshot)
                {
                    case AsyncStopState.None:
                        if (CompareExchangeAsyncStopState(AsyncStopState.Pending, snapshot))
                        {
                            return true;
                        }
                        break;

                    case AsyncStopState.Pending:
                    case AsyncStopState.Sent:
                        return false;

                    case AsyncStopState.StoppingEventInRoute:
                        if (CompareExchangeAsyncStopState(AsyncStopState.Pending, snapshot))
                        {
                            return false;
                        }
                        break;

                    case AsyncStopState.StopProcessingComplete:
                        if (CompareExchangeAsyncStopState(AsyncStopState.Sent, snapshot))
                        {
                            SendGeneratedStopComplete();
                            return false;
                        }
                        break;

                    default:
                        throw new ArgumentException("TODO: janraj, Invalid state?");
                }
            }
        }

        public void UpdateAsyncStopStateAfterEventSent(Guid riidEvent)
        {
            while (true)
            {
                AsyncStopState snapshot = (AsyncStopState)_asyncStopState;

                switch (snapshot)
                {
                    case AsyncStopState.None:
                        return;

                    case AsyncStopState.Pending:
                        if (CompareExchangeAsyncStopState(AsyncStopState.Sent, snapshot))
                        {
                            if (riidEvent.Equals(AD7StopCompleteEvent.IID))
                            {
                                return;
                            }
                            else
                            {
                                SendGeneratedStopComplete();
                            }
                        }
                        break;

                    case AsyncStopState.StoppingEventInRoute:
                        if (CompareExchangeAsyncStopState(AsyncStopState.StopProcessingComplete, snapshot))
                        {
                            return;
                        }
                        break;

                    default:
                        throw new ArgumentException("TODO: Unexpected");
                }
            }
        }

        internal void BeforeSendingStoppingEvent()
        {
            CompareExchangeAsyncStopState(AsyncStopState.StoppingEventInRoute, AsyncStopState.None);

        }

        internal void AfterSendingStoppingEvent(Guid riidEvent)
        {
            UpdateAsyncStopStateAfterEventSent(riidEvent);
        }

        private bool CompareExchangeAsyncStopState(AsyncStopState exchange, AsyncStopState comparand)
        {
            AsyncStopState original = (AsyncStopState)Interlocked.CompareExchange(ref _asyncStopState, (int)exchange, (int)comparand);
            return original == comparand;
        }

        private void SendGeneratedStopComplete()
        {
            if (LastEventThread == null)
            {
                throw new ArgumentException("TODO: janraj, LastEventThread should not be empty!");
            }

            _engineCallback.OnStopComplete(LastEventThread);
        }

        internal void ClearStoppingEventState()
        {
            _asyncStopState = (int)AsyncStopState.None;
        }
    }
}
